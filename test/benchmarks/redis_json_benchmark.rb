#!/usr/bin/env ruby
# frozen_string_literal: true

require 'redis'
require 'json'
require 'benchmark'
require 'securerandom'

# Configuration
REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'
TEST_SIZES = [1, 5, 10, 50, 100] # Size in MB
ITERATIONS = 3
TEST_CASE_KEY_PREFIX = 'coverband_benchmark_test'

# Create Redis connection
redis = Redis.new(url: REDIS_URL)

# Create Lua script for setting data with TTL
LUA_SCRIPT = <<~LUA
  local key = KEYS[1]
  local value = ARGV[1]
  local ttl = tonumber(ARGV[2])
  redis.call('SET', key, value)
  redis.call('EXPIRE', key, ttl)
  return 1
LUA

# Load Lua script
lua_sha = redis.script(:load, LUA_SCRIPT)

# Create large JSON data of specified size (in MB)
def generate_large_json(size_mb)
  # Create a structure similar to method traces
  result = {}
  
  # Generate enough random data to reach the target size
  target_bytes = size_mb * 1024 * 1024
  current_bytes = 0
  file_count = 0
  
  while current_bytes < target_bytes
    file_path = "/app/models/file_#{file_count}.rb"
    file_count += 1
    
    # Create random method names for this file
    methods = []
    method_count = rand(5..50)
    method_count.times do |i|
      methods << "method_#{i}_#{SecureRandom.hex(8)}"
    end
    
    result[file_path] = methods
    current_bytes = result.to_json.bytesize
  end
  
  result
end

# Clean up previous test keys
puts "Cleaning up previous test keys..."
previous_keys = redis.keys("#{TEST_CASE_KEY_PREFIX}*")
redis.del(*previous_keys) unless previous_keys.empty?

# Run benchmarks
puts "Running Redis SET benchmarks for large JSON objects..."
puts "-" * 80
puts "| Size (MB) | Direct SET (sec) | Lua Script (sec) | Direct:Lua Ratio | JSON Size (bytes) |"
puts "|-----------|------------------|------------------|------------------|------------------|"

TEST_SIZES.each do |size_mb|
  # Generate test data once per size
  test_data = generate_large_json(size_mb)
  json_data = test_data.to_json
  actual_size_bytes = json_data.bytesize
  actual_size_mb = actual_size_bytes / (1024.0 * 1024.0)
  
  # Keys for this test
  direct_key = "#{TEST_CASE_KEY_PREFIX}:direct:#{size_mb}mb"
  lua_key = "#{TEST_CASE_KEY_PREFIX}:lua:#{size_mb}mb"
  ttl = 3600 # 1 hour TTL
  
  # Benchmark direct SET
  direct_times = []
  ITERATIONS.times do
    direct_times << Benchmark.realtime do
      redis.set(direct_key, json_data, ex: ttl)
    end
  end
  direct_avg = direct_times.sum / direct_times.size
  
  # Benchmark Lua script
  lua_times = []
  ITERATIONS.times do
    lua_times << Benchmark.realtime do
      redis.evalsha(lua_sha, [lua_key], [json_data, ttl.to_s])
    end
  end
  lua_avg = lua_times.sum / lua_times.size
  
  # Calculate ratio
  ratio = lua_avg / direct_avg
  
  # Print results
  puts "| %.2f MB | %.6f sec | %.6f sec | %.2f:1 | %d |" % [
    actual_size_mb,
    direct_avg,
    lua_avg,
    ratio,
    actual_size_bytes
  ]
  
  # Clean up after each test
  redis.del(direct_key, lua_key)
end

puts "-" * 80
puts "\nMemory usage before tests: #{redis.info["used_memory_human"]}"

# Now let's test the maximum practical size
puts "\nTesting maximum practical size..."
begin
  max_sizes = [200, 300, 400]
  max_sizes.each do |size_mb|
    puts "Attempting #{size_mb}MB JSON..."
    test_data = generate_large_json(size_mb)
    json_data = test_data.to_json
    actual_size_bytes = json_data.bytesize
    actual_size_mb = actual_size_bytes / (1024.0 * 1024.0)
    
    key = "#{TEST_CASE_KEY_PREFIX}:max:#{size_mb}mb"
    
    start_time = Time.now
    redis.set(key, json_data, ex: ttl)
    duration = Time.now - start_time
    
    puts "  Success: #{actual_size_mb.round(2)}MB stored in #{duration.round(6)}s"
    redis.del(key)
  end
rescue => e
  puts "  Error at current size: #{e.message}"
end

puts "\nMemory usage after tests: #{redis.info["used_memory_human"]}"
puts "\nAll benchmarks completed."