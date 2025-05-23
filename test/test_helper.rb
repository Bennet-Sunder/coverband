# frozen_string_literal: true

require "bigdecimal"

original_verbosity = $VERBOSE
$VERBOSE = nil

if ENV["SKIP_SIMPLECOV"] || BigDecimal(RUBY_VERSION[0, 3]) >= BigDecimal("3.1")
  $SKIP_SIMPLECOV = true
end

require "rubygems"

unless $SKIP_SIMPLECOV
  require "simplecov"
  require "coveralls"
end

require "minitest/autorun"
require "minitest/stub_const"
require "mocha/minitest"
require "json"
require "redis"
require "resque"

require "coverband"
require "coverband/reporters/web"
require "coverband/utils/html_formatter"
require "coverband/utils/result"
require "coverband/utils/file_list"
require "coverband/utils/source_file"
require "coverband/utils/lines_classifier"
require "coverband/utils/results"
require "coverband/reporters/html_report"
require "coverband/reporters/json_report"
require "webmock/minitest"
require "spy/integration"

require_relative "unique_files"
$VERBOSE = original_verbosity

unless ENV["ONESHOT"] || $SKIP_SIMPLECOV
  SimpleCov.formatter = Coveralls::SimpleCov::Formatter
  SimpleCov.start do
    add_filter "test/forked"
  end

  Coveralls.wear!
end

module Coverband
  module Test
    TEST_DB = 2

    def self.redis
      @redis ||= Redis.new(db: TEST_DB)
    end

    def self.reset
      Coverband.configuration.reset
      Coverband.configuration.redis_namespace = "coverband_test"
      Coverband.configuration.store.instance_variable_set(:@redis_namespace, "coverband_test")
      Coverband.configuration.store.class.class_variable_set(:@@path_cache, {})
      Coverband.configuration.reset
      Coverband::Collectors::Coverage.instance.reset_instance
      Coverband::Utils::RelativeFileConverter.reset
      Coverband::Utils::AbsoluteFileConverter.reset
      Coverband.configuration.reporting_wiggle = 0
      Coverband.configuration.redis_namespace = "coverband_test"
      Coverband::Background.stop
      Coverband.configuration.store.instance_variable_set(:@redis, redis)
      redis.flushdb
    end

    def setup
      super
      Coverband::Test.reset
    end
  end
end

Minitest::Test.class_eval do
  prepend Coverband::Test
end

TEST_COVERAGE_FILE = "/tmp/fake_file.json"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))
$LOAD_PATH.unshift(File.dirname(__FILE__))

Mocha.configure do |c|
  c.stubbing_method_unnecessarily = :prevent
  c.stubbing_method_on_non_mock_object = :allow
  c.stubbing_method_on_nil = :prevent
end

def test(name, &block)
  test_name = :"test_#{name.gsub(/\s+/, "_")}"
  defined = begin
    instance_method(test_name)
  rescue
    false
  end
  raise "#{test_name} is already defined in #{self}" if defined

  if block
    define_method(test_name, &block)
  else
    define_method(test_name) do
      flunk "No implementation provided for #{name}"
    end
  end
end

def mock_file_hash(hash: "abcd")
  Coverband::Utils::FileHasher.expects(:hash_file).at_least_once.returns(hash)
end

def example_line
  [0, 1, 2]
end

def basic_coverage
  {"app_path/dog.rb" => example_line}
end

def increased_basic_coverage
  {"app_path/dog.rb" => [0, 2, 6]}
end

def basic_coverage_full_path
  {basic_coverage_file_full_path => example_line}
end

def basic_source_fixture_coverage
  {source_fixture("sample.rb") => example_line}
end

def basic_coverage_file_full_path
  "#{test_root}/dog.rb"
end

def source_fixture(filename)
  File.expand_path(File.join(File.dirname(__FILE__), "fixtures", filename))
end

def fixtures_root
  File.expand_path(File.join(File.dirname(__FILE__), "fixtures"))
end

def test_root
  File.expand_path(File.join(File.dirname(__FILE__)))
end

###
# This handles an issue where the store is setup in tests prior to being able to set the namespace
###
def store
  if Coverband.configuration.store.redis_namespace == "coverband_test"
    # noop
  else
    Coverband.configuration.redis_namespace = "coverband_test"
    Coverband.configuration.instance_variable_set(:@store, nil)
  end
  Coverband.configuration.store
end

# Taken from http://stackoverflow.com/questions/4459330/how-do-i-temporarily-redirect-stderr-in-ruby
def capture_stderr
  # The output stream must be an IO-like object. In this case we capture it in
  # an in-memory IO object so we can return the string value. You can assign any
  # IO object here.
  previous_stderr = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  # Restore the previous value of stderr (typically equal to STDERR).
  $stderr = previous_stderr
end

Coverband::Configuration.class_eval do
  def test_env
    true
  end
end
