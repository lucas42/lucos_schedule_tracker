require "sqlite3"

class Database
	SCHEDULE_TABLE = "schedule_v2"
	def initialize(db_path)

		# Open a database
		@db = SQLite3::Database.new db_path
		@db.results_as_hash = true
		if (!tableExists(SCHEDULE_TABLE))
			puts "Creating `#{SCHEDULE_TABLE}` table in database"
			@db.execute <<-SQL
				create table #{SCHEDULE_TABLE} (
					system TEXT PRIMARY KEY,
					frequency INTEGER,
					last_success TEXT,
					last_error TEXT,
					error_count INTEGER,
					message TEXT
				);
			SQL
		end
		["schedule"].each do |old_table|
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

	def updateScheduleSuccess(system, frequency)
		@db.execute("INSERT OR REPLACE INTO #{SCHEDULE_TABLE}(system, frequency, last_success, error_count, message) VALUES(?, ?, datetime('now'), 0, NULL)", [system, frequency])
	end

	def updateScheduleError(system, frequency, error_message)
		error_count = @db.get_first_value("SELECT error_count FROM #{SCHEDULE_TABLE} WHERE system = ?", system) || 0
		error_count += 1
		@db.execute("INSERT OR REPLACE INTO #{SCHEDULE_TABLE}(system, frequency, last_error, error_count, message) VALUES(?, ?, datetime('now'), ?, ?)", [system, frequency, error_count, error_message])
	end

	def getChecks
		checks = {}
		metrics = {}
		@db.execute("SELECT * FROM #{SCHEDULE_TABLE}") do |schedule|
			time_threshold = schedule["frequency"] * 3
			error_threshold = 2
			check = {
				:techDetail => "Checks whether any of the #{error_threshold} most recently finished runs of scheduled job '#{schedule["system"]}' were successful, and that the most recent happened in the last #{time_threshold} seconds"
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

			checks[schedule["system"]] = check
			metrics["#{schedule["system"]}_age"] = {
				:value => age,
				:techDetail => "The number of seconds since the scheduled job last completed",
			}
			metrics["#{schedule["system"]}_errors"] = {
				:value => schedule["error_count"],
				:techDetail => "The number of consecutive errors this scheduled job has had since the last success",
			}
		end
		return checks, metrics
	end
end