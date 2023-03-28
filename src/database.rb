require "sqlite3"

class Database
	def initialize(db_path)

		# Open a database
		@db = SQLite3::Database.new db_path
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

end