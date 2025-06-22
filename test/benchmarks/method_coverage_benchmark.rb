#!/usr/bin/env ruby
# frozen_string_literal: true

# This script benchmarks the overhead of Ruby's Coverage module with different modes:
# 1. No coverage
# 2. Method coverage only
#
# The benchmark simulates a Rails request cycle with controller, model, and view operations
#
# Run this script directly: ruby test/benchmarks/method_coverage_benchmark.rb
# Or with options: ruby test/benchmarks/method_coverage_benchmark.rb --iterations=50

require 'benchmark'
require 'benchmark/ips'
require 'optparse'
require 'json'
require 'ostruct'

# Parse command line options
options = { iterations: 20 }
OptionParser.new do |opts|
  opts.banner = "Usage: method_coverage_benchmark.rb [options]"
  opts.on("--iterations=ITERATIONS", Integer, "Number of request iterations (default: 20)") do |iterations|
    options[:iterations] = iterations
  end
end.parse!

# Classes to simulate a Rails application
module Rails
  class Controller
    attr_reader :params, :headers, :request
    
    def initialize(params = {}, headers = {})
      @params = params
      @headers = headers
      @request = OpenStruct.new(
        method: 'GET',
        path: '/users',
        remote_ip: '127.0.0.1',
        user_agent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
        referer: 'http://example.com/previous'
      )
    end
    
    def process_action
      # Authenticate user
      current_user = User.find(@params[:user_id]) if @params[:user_id]
      
      # Load data from models
      @users = User.all
      
      # Process data
      @processed_users = @users.map { |user| process_user(user) }
      
      # Render view
      render_view
      
      # Log request
      log_request
      
      # Return response
      {status: 200, body: JSON.generate(@processed_users)}
    end
    
    private
    
    def process_user(user)
      {
        id: user.id,
        name: user.full_name,
        email: user.email,
        admin: user.admin?,
        last_active: user.last_active_at,
        created: user.created_at
      }
    end
    
    def render_view
      # Simulate view rendering with a lot of method calls
      layout = render_layout
      
      # Render partials
      header = render_partial('header', {title: 'Users List'})
      footer = render_partial('footer', {copyright: "© #{Time.now.year}"})
      
      # Render user list
      user_list = render_partial('user_list', {users: @processed_users})
      
      # Assemble final view
      @rendered_view = layout.gsub('{{content}}', user_list)
        .gsub('{{header}}', header)
        .gsub('{{footer}}', footer)
    end
    
    def render_layout
      '<html><head><title>Users</title></head><body>{{header}}{{content}}{{footer}}</body></html>'
    end
    
    def render_partial(name, locals = {})
      case name
      when 'header'
        "<header><h1>#{locals[:title]}</h1></header>"
      when 'footer'
        "<footer>#{locals[:copyright]}</footer>"
      when 'user_list'
        users_html = locals[:users].map do |user|
          "<li>#{user[:name]} (#{user[:email]})</li>"
        end.join("\n")
        "<ul>#{users_html}</ul>"
      else
        ""
      end
    end
    
    def log_request
      # Simulate logging request details
      Logger.info("Processing #{@request.method} #{@request.path}")
      Logger.info("  Parameters: #{@params.inspect}")
      Logger.info("  Completed in 20.3ms")
    end
  end
  
  class Model
    attr_reader :attributes
    
    def initialize(attributes = {})
      @attributes = attributes
    end
    
    def method_missing(method_name, *args)
      attribute = method_name.to_s
      if attribute.end_with?('=')
        attribute = attribute.chop
        @attributes[attribute.to_sym] = args.first
      else
        @attributes[method_name]
      end
    end
    
    def respond_to_missing?(method_name, include_private = false)
      @attributes.key?(method_name.to_s.chomp('=').to_sym) || super
    end
    
    class << self
      def all
        @@records ||= []
      end
      
      def find(id)
        all.find { |record| record.id == id }
      end
      
      def create(attributes)
        record = new(attributes)
        all << record
        record
      end
    end
  end
  
  class User < Model
    def full_name
      "#{attributes[:first_name]} #{attributes[:last_name]}"
    end
    
    def admin?
      !!attributes[:admin]
    end
  end
  
  class Logger
    class << self
      def info(message)
        # In a real app, this would write to a log file
      end
      
      def error(message)
        # In a real app, this would write to a log file
      end
    end
  end
end

# Set up some test data
def seed_data
  # Create 100 users
  100.times do |i|
    Rails::User.create(
      id: i + 1,
      first_name: "User#{i}",
      last_name: "Smith",
      email: "user#{i}@example.com",
      admin: i % 10 == 0,
      last_active_at: Time.now - rand(100) * 3600,
      created_at: Time.now - rand(365) * 86400
    )
  end
end

# Simulate a Rails request with various controller and model operations
def simulate_rails_request(user_id = nil)
  controller = Rails::Controller.new({user_id: user_id})
  controller.process_action
end

# Helper to measure memory consumption
def memory_usage
  `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
end

puts "Benchmarking Coverage overhead for Rails request simulation (#{options[:iterations]} iterations)"
puts "Memory before any coverage: #{memory_usage.round(2)} MB"

# Set up data for benchmarks
seed_data
puts "Seeded test data with #{Rails::User.all.size} users"

# Define the different coverage modes to benchmark
coverage_modes = {
  "No Coverage" => lambda { 
    # Just run without Coverage
  },
  "Method Coverage" => lambda {
    require 'coverage'
    # Enable method coverage only
    Coverage.start(methods: true)
  }
}

# Warm up the Ruby VM
puts "\nWarming up..."
3.times { simulate_rails_request }
GC.start

# Run time benchmarks
puts "\nTime benchmarks:"
puts "================="

Benchmark.bmbm do |x|
  coverage_modes.each do |name, setup|
    x.report(name) do
      # Reset Coverage state between runs if previously enabled
      if defined?(Coverage) && Coverage.respond_to?(:result)
        begin
          Coverage.result
        rescue
          # Ignore if Coverage wasn't started
        end
      end
      
      setup.call
      options[:iterations].times do |i|
        # Use a different user each time to avoid caching effects
        simulate_rails_request(1 + (i % 100))
      end
      
      # Get coverage results if Coverage is active
      if defined?(Coverage) && Coverage.respond_to?(:result)
        begin
          Coverage.result
        rescue
          # Ignore if Coverage wasn't started
        end
      end
    end
    
    # Force GC between tests for more accurate memory measurements
    GC.start
  end
end

# Memory benchmarks
puts "\nMemory benchmarks:"
puts "=================="

coverage_modes.each do |name, setup|
  # Reset Coverage state between runs if previously enabled
  if defined?(Coverage) && Coverage.respond_to?(:result)
    begin
      Coverage.result
    rescue
      # Ignore if Coverage wasn't started
    end
  end
  
  GC.start
  before = memory_usage
  
  setup.call
  options[:iterations].times do |i|
    # Use a different user each time to avoid caching effects
    simulate_rails_request(1 + (i % 100))
  end
  
  # Get coverage results if Coverage is active
  if defined?(Coverage) && Coverage.respond_to?(:result)
    begin
      results = Coverage.result
      result_size = results.size
      puts "  Coverage result size: #{result_size} files"
    rescue
      # Ignore if Coverage wasn't started
    end
  end
  
  after = memory_usage
  puts "#{name}: #{(after - before).round(2)} MB increase (#{after.round(2)} MB total)"
end

# Now run IPS benchmark to show operations per second
puts "\nOperations per second (requests/second):"
puts "========================================"

Benchmark.ips do |x|
  x.time = 5
  x.warmup = 2
  
  coverage_modes.each do |name, setup|
    x.report(name) do
      # Reset Coverage state between runs if previously enabled
      if defined?(Coverage) && Coverage.respond_to?(:result)
        begin
          Coverage.result
        rescue
          # Ignore if Coverage wasn't started
        end
      end
      
      setup.call
      # Process a single request for IPS benchmark
      simulate_rails_request(rand(100) + 1)
      
      # Get coverage results if Coverage is active
      if defined?(Coverage) && Coverage.respond_to?(:result)
        begin
          Coverage.result
        rescue
          # Ignore if Coverage wasn't started
        end
      end
    end
  end
  
  x.compare!
end