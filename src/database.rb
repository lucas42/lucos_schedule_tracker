require "sqlite3"
require "date"

class Database
	SCHEDULE_TABLE = "schedule_v3"
	def initialize(db_path)

		# Open a database
		@db = SQLite3::Database.new db_path
		@db.results_as_hash = true
		if (!tableExists(SCHEDULE_TABLE))
			puts "Creating `#{SCHEDULE_TABLE}` table in database"
			@db.execute <<-SQL
				create table #{SCHEDULE_TABLE} (
					system TEXT NOT NULL,
					job_name TEXT NOT NULL DEFAULT '',
					frequency INTEGER,
					last_success TEXT,
					last_error TEXT,
					error_count INTEGER,
					message TEXT,
					PRIMARY KEY (system, job_name)
				);
			SQL
		end
		if tableExists("schedule_v2")
			puts "Migrating `schedule_v2` to `#{SCHEDULE_TABLE}`"
			@db.execute("INSERT OR IGNORE INTO #{SCHEDULE_TABLE}(system, job_name, frequency, last_success, last_error, error_count, message) SELECT system, '', frequency, last_success, last_error, error_count, message FROM schedule_v2")
		end
		["schedule", "schedule_v2"].each do |old_table|
			if (tableExists(old_table))
				puts "Deleting old table \"#{old_table}\""
				@db.execute("DROP TABLE #{old_table}")
			end
		end
	end

	def tableExists(tablename)
		@db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [tablename]) do |row|
			return true
		end
		return false
	end

	def updateScheduleSuccess(system, frequency, job_name = "")
		@db.execute("INSERT OR REPLACE INTO #{SCHEDULE_TABLE}(system, job_name, frequency, last_success, error_count, message) VALUES(?, ?, ?, datetime('now'), 0, NULL)", [system, job_name, frequency])
	end

	def updateScheduleError(system, frequency, error_message, job_name = "")
		error_count = @db.get_first_value("SELECT error_count FROM #{SCHEDULE_TABLE} WHERE system = ? AND job_name = ?", [system, job_name]) || 0
		error_count += 1
		@db.execute("INSERT OR REPLACE INTO #{SCHEDULE_TABLE}(system, job_name, frequency, last_error, error_count, message) VALUES(?, ?, ?, datetime('now'), ?, ?)", [system, job_name, frequency, error_count, error_message])
	end

	def deleteSchedule(system)
		@db.execute("DELETE FROM #{SCHEDULE_TABLE} WHERE system = ? AND job_name = ''", [system])
	end

	def deleteScheduleV2(system, job_name)
		@db.execute("DELETE FROM #{SCHEDULE_TABLE} WHERE system = ? AND job_name = ?", [system, job_name])
	end

	# Returns the alert threshold in seconds for a job with the given frequency.
	#
	# Rule:
	#   frequency < 4 days  →  frequency × 3         (unchanged)
	#   frequency ≥ 4 days  →  (frequency × 2) + 30 minutes
	#
	# The +30-minute term is jitter insurance: a slackless ×2 rule has zero
	# tolerance for run-length variance.  30 minutes is generous against typical
	# lucos run-lengths and trivial against the ≥8-day thresholds in the
	# long-frequency band.
	#
	# Note the step-change at the 4-day boundary: a job with frequency=3d23h
	# gets a ~12-day threshold; bump it to 4d and it gets ~8.5 days.  This is
	# intentional – callers choosing a value near the boundary should be aware.
	def calculate_time_threshold(frequency)
		four_days = 4 * 24 * 60 * 60
		if frequency < four_days
			frequency * 3
		else
			(frequency * 2) + (30 * 60)
		end
	end

	# Returns the consecutive-failure threshold for a job with the given frequency.
	#
	# Higher-frequency jobs get more tolerance to reduce noise from brief
	# upstream blips:
	#   frequency < 10 min  →  5
	#   frequency < 30 min  →  4
	#   frequency < 90 min  →  3
	#   frequency ≥ 90 min  →  2
	def calculate_error_threshold(frequency)
		ten_mins    = 10 * 60
		thirty_mins = 30 * 60
		ninety_mins = 90 * 60
		if frequency < ten_mins
			5
		elsif frequency < thirty_mins
			4
		elsif frequency < ninety_mins
			3
		else
			2
		end
	end

	def getChecks
		checks = {}
		metrics = {}
		@db.execute("SELECT * FROM #{SCHEDULE_TABLE}") do |schedule|
			time_threshold = calculate_time_threshold(schedule["frequency"])
			error_threshold = calculate_error_threshold(schedule["frequency"])
			check_key = schedule["job_name"].empty? ? schedule["system"] : "#{schedule["system"]}/#{schedule["job_name"]}"
			check = {
				:techDetail => "Checks whether any of the #{error_threshold} most recently finished runs of scheduled job '#{check_key}' were successful, and that the most recent happened in the last #{time_threshold} seconds"
			}
			last_run = DateTime.parse(schedule["last_success"] || schedule["last_error"])
			age = ((DateTime.now - last_run) * 24 * 60 * 60).to_i
			if schedule["error_count"] >= error_threshold
				check[:ok] = false
				check[:debug] = "Last #{schedule["error_count"]} runs of scheduled job errored. Latest at #{schedule["last_error"]}"
				unless schedule["message"].nil?
					check[:debug] += " with message \"#{schedule["message"]}\""
				end
			else
				if age < time_threshold
					check[:ok] = true
				else
					check[:ok] = false
					check[:debug] = "Job last ran at #{last_run}, which is #{age} seconds ago. (The threshold for erroring is an age of #{time_threshold}s)"
				end
			end

			checks[check_key] = check
			metrics["#{check_key}_age"] = {
				:value => age,
				:techDetail => "The number of seconds since the scheduled job last completed",
			}
			metrics["#{check_key}_errors"] = {
				:value => schedule["error_count"],
				:techDetail => "The number of consecutive errors this scheduled job has had since the last success",
			}
		end
		return checks, metrics
	end
end
