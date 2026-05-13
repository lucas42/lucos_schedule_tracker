require "minitest/autorun"
require "net/http"
require "json"
require "socket"
require "tempfile"

class ServerRoutingTest < Minitest::Test
	SERVER_RB = File.expand_path("../server.rb", __dir__)

	def setup
		# Unique SQLite file per test — no shared state between tests.
		@db_file = Tempfile.new(["schedule_tracker_test", ".sqlite"])
		@db_file.close

		# Capture server logs so failures are diagnosable.
		@server_log = Tempfile.new(["schedule_tracker_server", ".log"])
		@server_log.close

		# Grab a free port from the OS.
		port_socket = TCPServer.new("127.0.0.1", 0)
		@test_port = port_socket.addr[1].to_s
		port_socket.close

		# Spawn a fresh server for this test.
		@server_pid = spawn(
			{"PORT" => @test_port, "DB_PATH" => @db_file.path},
			"ruby", SERVER_RB,
			out: @server_log.path,
			err: [@server_log.path, "a"]
		)

		# Wait up to 2 s for the server to accept connections.
		20.times do
			begin
				TCPSocket.new("127.0.0.1", @test_port.to_i).close
				break
			rescue Errno::ECONNREFUSED
				sleep 0.1
			end
		end
	end

	def teardown
		Process.kill("TERM", @server_pid) rescue nil
		Process.wait(@server_pid) rescue nil
		unless failures.empty?
			puts "\n--- Server log for #{name} ---"
			begin
				puts File.read(@server_log.path)
			rescue => e
				puts "(log unavailable: #{e.message})"
			end
			puts "--- End server log ---"
		end
		@server_log.unlink rescue nil
		@db_file.unlink rescue nil
	end

	def get_request(path)
		Net::HTTP.start("127.0.0.1", @test_port.to_i) { |h| h.get(path) }
	end

	def post_json(path, body)
		Net::HTTP.start("127.0.0.1", @test_port.to_i) do |h|
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
