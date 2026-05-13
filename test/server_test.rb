require "minitest/autorun"
require "net/http"
require "json"
require "fileutils"
require "socket"

# Ensure the DB directory exists so the server can open its SQLite file.
FileUtils.mkdir_p("/var/lib/schedule_tracker")

TEST_PORT = "18765"

# Spawn the server once for the whole test run.
SERVER_PID = spawn({"PORT" => TEST_PORT}, "ruby", "server.rb", out: "/dev/null", err: "/dev/null")

# Wait up to 2 s for the server to accept connections.
20.times do
	begin
		TCPSocket.new("127.0.0.1", TEST_PORT.to_i).close
		break
	rescue Errno::ECONNREFUSED
		sleep 0.1
	end
end

Minitest.after_run { Process.kill("TERM", SERVER_PID) rescue nil }

class ServerRoutingTest < Minitest::Test
	def get_request(path)
		Net::HTTP.start("127.0.0.1", TEST_PORT.to_i) { |h| h.get(path) }
	end

	def post_json(path, body)
		Net::HTTP.start("127.0.0.1", TEST_PORT.to_i) do |h|
			req = Net::HTTP::Post.new(path, "Content-Type" => "application/json")
			req.body = JSON.dump(body)
			h.request(req)
		end
	end

	# Regression: the doubled path must now return 404, not 202.
	def test_doubled_report_status_path_returns_404
		response = post_json("/report-status/report-status", {"system" => "test", "frequency" => 60, "status" => "success"})
		assert_equal "404", response.code
	end

	# Happy path: a correctly-formed POST to /report-status still returns 202.
	def test_valid_report_status_returns_202
		response = post_json("/report-status", {"system" => "test", "frequency" => 60, "status" => "success"})
		assert_equal "202", response.code
	end

	# Any completely unknown path must return 404.
	def test_unknown_path_returns_404
		response = get_request("/does-not-exist")
		assert_equal "404", response.code
	end

	# /_info with extra path segments must return 404.
	def test_info_with_extra_path_returns_404
		response = get_request("/_info/extra")
		assert_equal "404", response.code
	end

	# /_info itself must still return 200.
	def test_info_returns_200
		response = get_request("/_info")
		assert_equal "200", response.code
	end
end
