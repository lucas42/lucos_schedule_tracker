require "simplecov"
SimpleCov.start do
	add_filter "/test/"
end

require "minitest/reporters"
Minitest::Reporters.use! [
	Minitest::Reporters::DefaultReporter.new(color: true),
	Minitest::Reporters::JUnitReporter.new("test-results")
]
