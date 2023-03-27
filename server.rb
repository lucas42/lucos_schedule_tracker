#!/usr/bin/ruby

require 'net/http'
require 'uri'
require 'json'
require 'time'


$stdout.sync = true
$stderr.sync = true
Thread.abort_on_exception = true

port = ENV['PORT'] || 8024
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
			case path[1]
				when 'report-status'
					if http_method == "POST"
						# TODO: Write logic goes here
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
					info = {
						system: "lucos_schedule_tracker",
						checks: {
							# TOOD: Read logic goes here
						},
						metrics: {},
						ci: {
							circle: "gh/lucas42/lucos_schedule_tracker",
						}
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
					client.puts
					client.puts(e.message)
				else
					status = 500
					client.puts("HTTP/1.1 500 Internal Error")
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
