require_relative "test_helper"
require "minitest/autorun"
require "sqlite3"
require_relative "../database"

# Use an in-memory database so tests are fast and leave no state on disk.
def make_db
	Database.new(":memory:")
end

class CalculateTimeThresholdTest < Minitest::Test
	ONE_DAY    = 24 * 60 * 60        #  86_400 s
	FOUR_DAYS  = 4 * ONE_DAY         # 345_600 s
	SEVEN_DAYS = 7 * ONE_DAY         # 604_800 s
	THIRTY_MIN = 30 * 60             #   1_800 s

	def setup
		@db = make_db
	end

	# Sub-4-day jobs use frequency × 3 (unchanged rule).
	def test_one_day_uses_triple_frequency
		assert_equal ONE_DAY * 3, @db.calculate_time_threshold(ONE_DAY)
	end

	def test_just_under_four_days_uses_triple_frequency
		just_under = FOUR_DAYS - 1
		assert_equal just_under * 3, @db.calculate_time_threshold(just_under)
	end

	# Exactly 4 days hits the ≥4-day branch.
	def test_exactly_four_days_uses_double_plus_jitter
		assert_equal (FOUR_DAYS * 2) + THIRTY_MIN, @db.calculate_time_threshold(FOUR_DAYS)
	end

	# Seven-day jobs (e.g. lucos_arachne_compaction) get ~14 days instead of 21.
	def test_seven_days_uses_double_plus_jitter
		assert_equal (SEVEN_DAYS * 2) + THIRTY_MIN, @db.calculate_time_threshold(SEVEN_DAYS)
	end

	# Step-change at the boundary: 3d23h is sub-4d; 4d is ≥4d.
	# 3d23h threshold > 4d threshold (the old regime was more lenient here).
	def test_step_change_at_boundary
		three_days_23h = (3 * ONE_DAY) + (23 * 3600)
		threshold_just_under = @db.calculate_time_threshold(three_days_23h)
		threshold_four_days  = @db.calculate_time_threshold(FOUR_DAYS)
		assert threshold_just_under > threshold_four_days,
			"Expected sub-4-day threshold (#{threshold_just_under}) > 4-day threshold (#{threshold_four_days})"
	end
end

class CalculateErrorThresholdTest < Minitest::Test
	ONE_DAY     = 24 * 60 * 60
	TEN_MINS    = 10 * 60
	THIRTY_MINS = 30 * 60
	NINETY_MINS = 90 * 60

	def setup
		@db = make_db
	end

	# frequency < 10 min → 5
	def test_sixty_seconds_gets_threshold_of_five
		assert_equal 5, @db.calculate_error_threshold(60)
	end

	def test_just_under_ten_minutes_gets_threshold_of_five
		assert_equal 5, @db.calculate_error_threshold(TEN_MINS - 1)
	end

	# frequency ≥ 10 min, < 30 min → 4
	def test_exactly_ten_minutes_gets_threshold_of_four
		assert_equal 4, @db.calculate_error_threshold(TEN_MINS)
	end

	def test_fifteen_minutes_gets_threshold_of_four
		assert_equal 4, @db.calculate_error_threshold(15 * 60)
	end

	# frequency ≥ 30 min, < 90 min → 3
	def test_exactly_thirty_minutes_gets_threshold_of_three
		assert_equal 3, @db.calculate_error_threshold(THIRTY_MINS)
	end

	def test_one_hour_gets_threshold_of_three
		assert_equal 3, @db.calculate_error_threshold(60 * 60)
	end

	# frequency ≥ 90 min → 2
	def test_exactly_ninety_minutes_gets_threshold_of_two
		assert_equal 2, @db.calculate_error_threshold(NINETY_MINS)
	end

	def test_one_day_job_gets_threshold_of_two
		assert_equal 2, @db.calculate_error_threshold(ONE_DAY)
	end
end

class MigrationTest < Minitest::Test
	def test_migrates_rows_from_schedule_v2
		db_file = Tempfile.new(["migration_test", ".sqlite"])
		db_file.close

		# Manually seed schedule_v2 with a row
		raw_db = SQLite3::Database.new(db_file.path)
		raw_db.execute(<<~SQL)
			CREATE TABLE schedule_v2 (
				system TEXT PRIMARY KEY,
				frequency INTEGER,
				last_success TEXT,
				last_error TEXT,
				error_count INTEGER,
				message TEXT
			)
		SQL
		raw_db.execute(<<~SQL)
			INSERT INTO schedule_v2(system, frequency, last_success, error_count)
			VALUES('old_system', 3600, datetime('now'), 0)
		SQL
		raw_db.close

		db = Database.new(db_file.path)

		checks, = db.getChecks
		assert checks.key?("old_system"), "Migrated row should appear as 'old_system'"
		refute db.tableExists("schedule_v2"), "schedule_v2 should be dropped after migration"
	ensure
		db_file.unlink rescue nil
	end

	def test_idempotent_when_schedule_v3_already_exists
		db_file = Tempfile.new(["idempotent_test", ".sqlite"])
		db_file.close

		Database.new(db_file.path)
		db = Database.new(db_file.path) # second init must not error

		checks, = db.getChecks
		assert_equal({}, checks, "Expected empty checks on fresh db after re-init")
	ensure
		db_file.unlink rescue nil
	end
end

class V2DatabaseTest < Minitest::Test
	ONE_DAY = 24 * 60 * 60

	def setup
		@db = make_db
	end

	def test_success_with_job_name_keyed_by_system_slash_job
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "ingestor_dbpedia")
		checks, = @db.getChecks
		assert checks.key?("lucos_arachne/ingestor_dbpedia"), "Named job should have composite key"
	end

	def test_success_without_job_name_keyed_by_system_only
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY)
		checks, = @db.getChecks
		assert checks.key?("lucos_arachne"), "Row with empty job_name should use system as key"
	end

	def test_v1_and_v2_empty_job_name_address_same_row
		@db.updateScheduleSuccess("shared_sys", ONE_DAY)      # v1 call
		@db.updateScheduleSuccess("shared_sys", ONE_DAY, "")  # v2 call, job_name=''
		checks, = @db.getChecks
		assert_equal 1, checks.length, "v1 and v2 with job_name='' should address the same row"
	end

	def test_age_metric_uses_composite_key_for_named_job
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "my_job")
		_, metrics = @db.getChecks
		assert metrics.key?("lucos_arachne/my_job_age")
		assert metrics.key?("lucos_arachne/my_job_errors")
	end

	def test_delete_schedule_removes_empty_job_name_row
		@db.updateScheduleSuccess("test_system", ONE_DAY)
		@db.deleteSchedule("test_system")
		checks, = @db.getChecks
		refute checks.key?("test_system"), "v1 deleteSchedule should remove the (system, '') row"
	end

	def test_delete_schedule_does_not_affect_named_jobs
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY)
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "my_job")
		@db.deleteSchedule("lucos_arachne")
		checks, = @db.getChecks
		refute checks.key?("lucos_arachne"), "v1 delete should remove the empty-job_name row"
		assert checks.key?("lucos_arachne/my_job"), "Named job should be unaffected by v1 delete"
	end

	def test_delete_schedule_v2_removes_named_row
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "my_job")
		@db.deleteScheduleV2("lucos_arachne", "my_job")
		checks, = @db.getChecks
		refute checks.key?("lucos_arachne/my_job"), "v2 delete should remove the named row"
	end

	def test_delete_schedule_v2_is_idempotent
		# Deleting a non-existent row must not raise
		@db.deleteScheduleV2("nonexistent", "job")
	end

	def test_error_with_job_name_accumulates_error_count
		@db.updateScheduleError("lucos_arachne", ONE_DAY, "oops", "my_job")
		@db.updateScheduleError("lucos_arachne", ONE_DAY, "oops again", "my_job")
		checks, = @db.getChecks
		refute checks["lucos_arachne/my_job"][:ok], "Two consecutive errors on a daily job should alert"
	end
end

class GetChecksTest < Minitest::Test
	ONE_DAY    = 24 * 60 * 60
	SEVEN_DAYS = 7 * ONE_DAY

	def setup
		@db = make_db
	end

	def test_recent_success_is_ok
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		checks, = @db.getChecks
		assert checks["test_job"][:ok], "Expected recent success to be OK"
	end

	def test_tech_detail_reflects_threshold
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		checks, = @db.getChecks
		expected_threshold = @db.calculate_time_threshold(ONE_DAY)
		assert_includes checks["test_job"][:techDetail], expected_threshold.to_s
	end

	def test_seven_day_job_tech_detail_reflects_tightened_threshold
		@db.updateScheduleSuccess("weekly_job", SEVEN_DAYS)
		checks, = @db.getChecks
		expected_threshold = @db.calculate_time_threshold(SEVEN_DAYS)
		# ~14 days + 30 min, not the old 21 days
		assert_includes checks["weekly_job"][:techDetail], expected_threshold.to_s
		refute_includes checks["weekly_job"][:techDetail], (SEVEN_DAYS * 3).to_s,
			"Should not use the old × 3 threshold for a 7-day job"
	end

	def test_age_metric_is_present
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		_, metrics = @db.getChecks
		assert metrics.key?("test_job_age")
		assert metrics.key?("test_job_errors")
	end

	# High-frequency jobs (< 10 min, threshold 5) tolerate 4 errors before alerting.
	def test_two_consecutive_errors_not_enough_to_alert_for_high_frequency_job
		one_minute = 60
		@db.updateScheduleError("test_job", one_minute, "something went wrong")
		@db.updateScheduleError("test_job", one_minute, "something went wrong again")
		checks, = @db.getChecks
		assert checks["test_job"][:ok], "Expected 2 consecutive errors to still be OK for a 60s job (threshold is 5)"
	end

	# Two consecutive errors on a daily job (threshold 2) should alert.
	def test_consecutive_errors_alerts
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong")
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong again")
		checks, = @db.getChecks
		refute checks["test_job"][:ok], "Expected 2 consecutive errors to be not OK for a 1-day job (threshold is 2)"
	end

	# Weekly jobs (threshold 2). Two errors should still alert.
	def test_two_consecutive_errors_alert_for_long_cadence_job
		@db.updateScheduleError("weekly_job", SEVEN_DAYS, "something went wrong")
		@db.updateScheduleError("weekly_job", SEVEN_DAYS, "something went wrong again")
		checks, = @db.getChecks
		refute checks["weekly_job"][:ok], "Expected 2 consecutive errors to be not OK for a 7-day job (threshold is 2)"
	end
end

class GetJobsTest < Minitest::Test
	ONE_DAY    = 24 * 60 * 60
	ONE_MINUTE = 60

	def setup
		@db = make_db
	end

	def test_empty_db_returns_empty_array
		assert_equal [], @db.getJobs
	end

	def test_single_v2_row_with_job_name
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "ingestor_dbpedia")
		jobs = @db.getJobs
		assert_equal 1, jobs.length
		job = jobs.first
		assert_equal "lucos_arachne", job[:system]
		assert_equal "ingestor_dbpedia", job[:job_name]
		assert job[:check][:ok]
		assert job[:metrics][:age].is_a?(Hash)
		assert job[:metrics][:errors].is_a?(Hash)
	end

	def test_single_v1_shaped_row_with_empty_job_name
		@db.updateScheduleSuccess("lucos_arachne_ingestor_dbpedia", ONE_DAY)
		jobs = @db.getJobs
		assert_equal 1, jobs.length
		job = jobs.first
		assert_equal "lucos_arachne_ingestor_dbpedia", job[:system]
		assert_equal "", job[:job_name]
		assert job[:check][:ok]
	end

	def test_mixed_v1_and_v2_rows_are_all_returned
		@db.updateScheduleSuccess("lucos_arachne_ingestor_dbpedia", ONE_DAY)
		@db.updateScheduleSuccess("lucos_arachne", ONE_DAY, "ingestor_dbpedia")
		assert_equal 2, @db.getJobs.length
	end

	def test_failing_check_last_error_older_than_threshold
		# Write an error so the job is tracked, then advance time by simulating
		# an old timestamp via a direct DB update.
		@db.updateScheduleError("old_job", ONE_MINUTE, "oops")
		@db.instance_variable_get(:@db).execute(
			"UPDATE schedule_v3 SET last_error = datetime('now', '-1 year') WHERE system = 'old_job'"
		)
		jobs = @db.getJobs
		refute jobs.first[:check][:ok], "Job with error older than threshold should not be OK"
	end

	def test_error_count_threshold_tripped
		# Daily job has error_threshold of 2; two consecutive errors should alert.
		@db.updateScheduleError("daily_job", ONE_DAY, "something broke")
		@db.updateScheduleError("daily_job", ONE_DAY, "still broken")
		job = @db.getJobs.first
		refute job[:check][:ok], "Two consecutive errors on a daily job should not be OK"
		assert_includes job[:check][:debug], "2 runs"
	end

	def test_metrics_shape_is_correct
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		job = @db.getJobs.first
		assert job[:metrics][:age].key?(:value)
		assert job[:metrics][:age].key?(:techDetail)
		assert job[:metrics][:errors].key?(:value)
		assert job[:metrics][:errors].key?(:techDetail)
		assert_equal 0, job[:metrics][:errors][:value]
	end

	def test_tech_detail_contains_threshold
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		job = @db.getJobs.first
		expected_threshold = @db.calculate_time_threshold(ONE_DAY)
		assert_includes job[:check][:techDetail], expected_threshold.to_s
	end
end
