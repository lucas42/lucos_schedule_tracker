require_relative "test_helper"
require "minitest/autorun"
require "net/http"
require "json"
require "socket"
require "tempfile"

class ServerRoutingTest < Minitest::Test
	SERVER_RB = File.expand_path("../server.rb", __dir__).freeze

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
			{ "PORT" => @test_port, "DB_PATH" => @db_file.path },
			"ruby", SERVER_RB,
			out: @server_log.path,
			err: [@server_log.path, "a"]
		)

		# Wait up to 2 s for the server to accept connections.
		20.times do
			TCPSocket.new("127.0.0.1", @test_port.to_i).close
			break
		rescue Errno::ECONNREFUSED
			sleep 0.1
		end
	end

	def teardown
		Process.kill("TERM", @server_pid) rescue nil
		Process.wait(@server_pid) rescue nil
		unless failures.empty?
			puts "\n--- Server log for #{name} ---"
			begin
				puts File.read(@server_log.path)
			rescue StandardError => e
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

	def delete_request(path)
		Net::HTTP.start("127.0.0.1", @test_port.to_i) { |h| h.delete(path) }
	end

	# Regression: the doubled path must now return 404, not 202.
	def test_doubled_report_status_path_returns_404
		response = post_json("/report-status/report-status", { "system" => "test", "frequency" => 60, "status" => "success" })
		assert_equal "404", response.code
	end

	# Happy path: a correctly-formed POST to /report-status still returns 202.
	def test_valid_report_status_returns_202
		response = post_json("/report-status", { "system" => "test", "frequency" => 60, "status" => "success" })
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

class V2ServerRoutingTest < ServerRoutingTest
	# ── v2 POST /v2/report-status ────────────────────────────────────────────

	def test_v2_report_status_happy_path_returns_202
		body = { "system" => "lucos_arachne", "job_name" => "ingestor_dbpedia", "frequency" => 86_400, "status" => "success" }
		response = post_json("/v2/report-status", body)
		assert_equal "202", response.code
	end

	def test_v2_report_status_omitted_job_name_returns_202
		body = { "system" => "lucos_arachne", "frequency" => 86_400, "status" => "success" }
		response = post_json("/v2/report-status", body)
		assert_equal "202", response.code
	end

	def test_v2_report_status_missing_system_returns_400
		response = post_json("/v2/report-status", { "frequency" => 60, "status" => "success" })
		assert_equal "400", response.code
	end

	def test_v2_report_status_missing_frequency_returns_400
		response = post_json("/v2/report-status", { "system" => "test", "status" => "success" })
		assert_equal "400", response.code
	end

	def test_v2_report_status_missing_status_returns_400
		response = post_json("/v2/report-status", { "system" => "test", "frequency" => 60 })
		assert_equal "400", response.code
	end

	def test_v2_report_status_with_extra_path_segment_returns_404
		response = post_json("/v2/report-status/extra", { "system" => "test", "frequency" => 60, "status" => "success" })
		assert_equal "404", response.code
	end

	# ── v1 POST is an unchanged shim ─────────────────────────────────────────

	def test_v1_report_status_still_works_after_v2_added
		response = post_json("/report-status", { "system" => "test", "frequency" => 60, "status" => "success" })
		assert_equal "202", response.code
	end

	# ── v2 DELETE /v2/schedule/{system}/{job_name} ────────────────────────────

	def test_v2_delete_existing_row_returns_204
		body = { "system" => "lucos_arachne", "job_name" => "my_job", "frequency" => 3_600, "status" => "success" }
		post_json("/v2/report-status", body)
		response = delete_request("/v2/schedule/lucos_arachne/my_job")
		assert_equal "204", response.code
	end

	def test_v2_delete_nonexistent_row_returns_204
		response = delete_request("/v2/schedule/nonexistent_system/nonexistent_job")
		assert_equal "204", response.code
	end

	def test_v2_delete_missing_job_name_returns_404
		response = delete_request("/v2/schedule/lucos_arachne")
		assert_equal "404", response.code
	end

	def test_v2_delete_extra_path_segment_returns_404
		response = delete_request("/v2/schedule/lucos_arachne/my_job/extra")
		assert_equal "404", response.code
	end

	# ── v1 DELETE addresses (system, '') row ─────────────────────────────────

	def test_v1_delete_addresses_empty_job_name_row
		# Write via v1; confirm the row appears in /jobs; delete via v1; confirm gone.
		post_json("/report-status", { "system" => "cleanup_sys", "frequency" => 3_600, "status" => "success" })
		jobs_before = JSON.parse(get_request("/jobs").body)
		assert jobs_before.any? { |j| j["system"] == "cleanup_sys" }, "Row should appear in /jobs before delete"

		response = delete_request("/schedule/cleanup_sys")
		assert_equal "204", response.code

		jobs_after = JSON.parse(get_request("/jobs").body)
		refute jobs_after.any? { |j| j["system"] == "cleanup_sys" }, "Row should be gone from /jobs after v1 delete"
	end

	# ── Same row addressed by v1 and v2 with job_name='' ─────────────────────

	def test_same_row_addressed_by_v1_and_v2_with_empty_job_name
		# Both v1 POST and v2 POST (omitted job_name) should address the same row.
		post_json("/report-status", { "system" => "shared_sys", "frequency" => 3_600, "status" => "success" })
		post_json("/v2/report-status", { "system" => "shared_sys", "frequency" => 3_600, "status" => "success" })

		jobs = JSON.parse(get_request("/jobs").body)
		assert_equal 1, jobs.select { |j| j["system"] == "shared_sys" }.length,
			"v1 and v2 with omitted job_name should produce exactly one row"
	end

	# ── GET /jobs ─────────────────────────────────────────────────────────────

	def test_jobs_returns_empty_array_when_no_rows
		response = get_request("/jobs")
		assert_equal "200", response.code
		assert_equal [], JSON.parse(response.body)
	end

	def test_jobs_returns_populated_entries
		body = { "system" => "lucos_arachne", "job_name" => "my_job", "frequency" => 3_600, "status" => "success" }
		post_json("/v2/report-status", body)
		jobs = JSON.parse(get_request("/jobs").body)
		assert_equal 1, jobs.length
		job = jobs.first
		assert_equal "lucos_arachne", job["system"]
		assert_equal "my_job", job["job_name"]
		assert job["check"]["ok"]
		assert job["metrics"]["age"].key?("value")
		assert job["metrics"]["errors"].key?("value")
	end

	def test_jobs_with_extra_path_segment_returns_404
		response = get_request("/jobs/extra")
		assert_equal "404", response.code
	end
end
