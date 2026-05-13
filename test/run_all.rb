# Single entry point that loads every *_test.rb under test/ and lets Minitest
# aggregate the results.  Run instead of chaining individual files with &&.
require_relative "test_helper"
Dir.glob(File.join(__dir__, "**", "*_test.rb")).sort.each do |test_file|
	require test_file
end
