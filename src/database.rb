require "sqlite3"

class Database
	def initialize(db_path)

		# Open a database
		@db = SQLite3::Database.new db_path
		@db.results_as_hash = true
		if (!tableExists("schedule"))
			puts "Creating `schedule` table in database"
			@db.execute <<-SQL
				create table schedule (
					system TEXT PRIMARY KEY,
					frequency INTEGER,
					last_success TEXT,
					last_error TEXT,
					message TEXT
				);
			SQL
		end
	end

	def tableExists(tablename)
		@db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [tablename]) do |row|
			return true
		end
		return false
	end

	def updateScheduleSuccess(system, frequency)
		@db.execute("INSERT OR REPLACE INTO schedule(system, frequency, last_success, message) VALUES(?, ?, datetime('now'), NULL)", [system, frequency])
	end

	def updateScheduleError(system, frequency, error_message)
		@db.execute("INSERT OR REPLACE INTO schedule(system, frequency, last_error, message) VALUES(?, ?, datetime('now'), ?)", [system, frequency, error_message])
	end

	def getChecks
		checks = {}
		metrics = {}
		@db.execute("SELECT * FROM schedule") do |schedule|
			threshold = schedule["frequency"] * 2
			check = {
				:techDetail => "Checks whether the most recently finished run of scheduled job '#{schedule["system"]}' was succesful and happened in the last #{threshold} seconds"
			}
			last_run = DateTime.parse(schedule["last_success"] || schedule["last_error"])
			age = ((DateTime.now - last_run) * 24 * 60 * 60).to_i
			if schedule["last_success"].nil?
				check[:ok] = false
				check[:debug] = "Last run of schedule job errored at #{schedule["last_error"]}"
				unless schedule["message"].nil?
					check[:debug] += " with message \"#{schedule["message"]}\""
				end
			else
				if age < threshold
					check[:ok] = true
				else
					check[:ok] = false
					check[:debug] = "Job last ran at #{schedule["last_success"]}, which is #{age} seconds ago. (The threshold for erroring is an age of #{threshold}s)"
				end
			end

			checks[schedule["system"]] = check
			metrics[schedule["system"]] = {
				:value => age,
				:techDetail => "The number of seconds since the scheduled job last completed",
			}
		end
		return checks, metrics
	end
end