require "minitest/autorun"
require "sqlite3"
require_relative "database"

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
	ONE_DAY    = 24 * 60 * 60
	FOUR_DAYS  = 4 * ONE_DAY
	SEVEN_DAYS = 7 * ONE_DAY

	def setup
		@db = make_db
	end

	# Sub-4-day jobs: floor(frequency × 3 / frequency) = 3
	def test_high_frequency_job_gets_threshold_of_three
		assert_equal 3, @db.calculate_error_threshold(60)  # 60s job
	end

	def test_one_day_job_gets_threshold_of_three
		assert_equal 3, @db.calculate_error_threshold(ONE_DAY)
	end

	def test_just_under_four_days_gets_threshold_of_three
		assert_equal 3, @db.calculate_error_threshold(FOUR_DAYS - 1)
	end

	# 4+ day jobs: floor((frequency × 2 + 1800) / frequency) = 2
	def test_exactly_four_days_gets_threshold_of_two
		assert_equal 2, @db.calculate_error_threshold(FOUR_DAYS)
	end

	def test_seven_day_job_gets_threshold_of_two
		assert_equal 2, @db.calculate_error_threshold(SEVEN_DAYS)
	end
end

class GetChecksTest < Minitest::Test
	ONE_DAY   = 24 * 60 * 60
	SEVEN_DAYS = 7 * ONE_DAY

	def setup
		@db = make_db
	end

	def test_recent_success_is_ok
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		checks, _ = @db.getChecks
		assert checks["test_job"][:ok], "Expected recent success to be OK"
	end

	def test_tech_detail_reflects_threshold
		@db.updateScheduleSuccess("test_job", ONE_DAY)
		checks, _ = @db.getChecks
		expected_threshold = @db.calculate_time_threshold(ONE_DAY)
		assert_includes checks["test_job"][:techDetail], expected_threshold.to_s
	end

	def test_seven_day_job_tech_detail_reflects_tightened_threshold
		@db.updateScheduleSuccess("weekly_job", SEVEN_DAYS)
		checks, _ = @db.getChecks
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

	# Sub-4-day jobs now have error_threshold 3 (not 2).
	# Two consecutive errors should still be OK.
	def test_two_consecutive_errors_not_enough_to_alert_for_high_frequency_job
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong")
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong again")
		checks, _ = @db.getChecks
		assert checks["test_job"][:ok], "Expected 2 consecutive errors to still be OK for a 1-day job (threshold is now 3)"
	end

	# Three consecutive errors on a sub-4-day job should alert.
	def test_consecutive_errors_alerts
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong")
		@db.updateScheduleError("test_job", ONE_DAY, "something went wrong again")
		@db.updateScheduleError("test_job", ONE_DAY, "third failure")
		checks, _ = @db.getChecks
		refute checks["test_job"][:ok], "Expected 3 consecutive errors to be not OK for a 1-day job"
	end

	# 4+ day jobs retain error_threshold 2. Two errors should still alert.
	def test_two_consecutive_errors_alert_for_long_cadence_job
		@db.updateScheduleError("weekly_job", SEVEN_DAYS, "something went wrong")
		@db.updateScheduleError("weekly_job", SEVEN_DAYS, "something went wrong again")
		checks, _ = @db.getChecks
		refute checks["weekly_job"][:ok], "Expected 2 consecutive errors to be not OK for a 7-day job (threshold is 2)"
	end
end
