#!/usr/bin/ruby

require 'net/http'
require 'uri'
require 'json'
require 'time'
require './database.rb'

$stdout.sync = true
$stderr.sync = true
Thread.abort_on_exception = true

db = Database.new("/var/lib/schedule_tracker/schedule.sqlite")

port = ENV['PORT'] || raise("Enviornment Variable PORT not set")
server = TCPServer.open(port)
puts 'server running on port '+port
loop {
	Thread.start(server.accept) do |client|
		request_time = Time.now.utc.iso8601
		status = "?"
		header = nil
		uristr = "/"
		remote_ip = "unknown_client"
		begin
			_, _, _, remote_ip = client.peeraddr
			while line = client.gets
				if header.nil?
					header = line.strip
				end
				if line.start_with?("Content-Length: ")
					request_length = line.split(': ')[1].strip.to_i
				end
				if line.start_with?("Content-Type: ")
					request_type = line.split(': ')[1].strip
				end
				if line == "\r\n"
					break
				end
			end
			if header.nil?
				puts "Incomplete HTTP request, closing connection to "+remote_ip
				client.close
				next
			end
			header_parts = header.split(' ')
			http_method = header_parts[0].upcase
			uristr = header_parts[1]
			uri = URI(uristr)
			path = uri.path.gsub('..','').split('/')
			body = nil
			if http_method == "POST"
				raw_body = client.read(request_length)
				if request_type == "application/json"
					begin
						body = JSON.parse(raw_body)
					rescue Exception => e
						raise "Can't parse JSON: "+e.message
					end
				else
					raise "This endpoint doesn't support "+(request_type||"unknown file type")
				end
			end
			case path[1]
				when 'report-status'
					if http_method == "POST"
						['system', 'frequency', 'status'].each { |field|
							if body[field].nil?
								raise "Bad Request: Missing `#{field}` field"
							end
						}
						frequency = body['frequency'].to_i
						if frequency == 0
							raise "Bad Request: `frequency` must be a positive integer"
						end
						case body['status']
						when "success"
							db.updateScheduleSuccess(body['system'], frequency)
						when "error"
							db.updateScheduleError(body['system'], frequency, body['message'])
						else
							raise "Bad Request: Unrecognised value for `status` '#{body['status']}'"
						end
						status = 202
						client.puts("HTTP/1.1 202 Accepted")
						client.puts("")
					else
						status = 405
						client.puts("HTTP/1.1 405 Method Not Allowed")
						client.puts("Allow: POST")
						client.puts("Content-Type: text/plain")
						client.puts("")
						client.puts("Endpoint only accepts POST requests")
					end
				when "_info"
					status = 200
					checks, metrics = db.getChecks
					info = {
						:system => "lucos_schedule_tracker",
						:checks => checks,
						:metrics => metrics,
						:ci => {
							:circle => "gh/lucas42/lucos_schedule_tracker",
						},
						:network_only => true,
						:show_on_homepage => false,
					}
					client.puts("HTTP/1.1 200 OK")
					client.puts("Content-Type: application/json; Charset=UTF-8")
					client.puts("")
					client.puts(info.to_json)
				else
					raise "File Not Found"
			end
		rescue Exception => e
			if header.nil?
				puts "Exception occurred before HTTP request was completed "+remote_ip
				puts e.message
				puts e.backtrace
				client.close
				next
			end
			begin
				if e.message.end_with?("Not Found")
					status = 404
					client.puts("HTTP/1.1 404 "+e.message)
					client.puts("Content-Type: text/plain")
					client.puts
					client.puts(e.message)
				elsif e.message.start_with?("Bad Request") || e.message.start_with?("Can't parse JSON")
					status = 400
					client.puts("HTTP/1.1 400 Bad Request")
					client.puts("Content-Type: text/plain")
					client.puts
					client.puts(e.message)
				elsif e.message.start_with?("This endpoint doesn't support")
					status = 415
					client.puts("HTTP/1.1 415 Unsupported Media Type")
					client.puts("Content-Type: text/plain")
					client.puts
					client.puts(e.message)
				else
					status = 500
					client.puts("HTTP/1.1 500 Internal Error")
					client.puts("Content-Type: text/plain")
					client.puts
					client.puts(e.message)
					client.puts(e.backtrace)
					puts e.message
					puts e.backtrace
				end
			rescue Exception => rescueException
				puts "Failed to send error page to client"
				puts e.message
				puts e.backtrace
				puts rescueException.message
				puts rescueException.backtrace
			end
		end
		puts remote_ip+" - - \""+header+"\" ["+request_time+"] "+status.to_s+" -"
		client.close
	end
}
