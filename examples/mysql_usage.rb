#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Replacing Redis with MySQL for Coverband storage
# This demonstrates minimal changes needed to swap storage backends

require 'coverband'

# Before (Redis-based):
# Coverband.configure do |config|
#   config.store = Coverband::Adapters::RedisStore.new(Redis.new(url: redis_url))
# end

# After (MySQL-based):
Coverband.configure do |config|
  # Simply replace the store - all method tracing remains the same
  config.store = Coverband::Storage::MysqlJsonStore.new(
    batch_size: 50,  # Optimize for your workload
    chunk_size: 10   # Optimize for your database
  )
  
  # All other Coverband configuration remains identical
  config.track_views = true
  config.track_routes = true
  config.track_translations = true
end

# Usage remains exactly the same - no changes to application code
puts "Coverband configured with MySQL storage instead of Redis"
puts "Store type: #{Coverband.configuration.store.class}"
puts "Coverage tracking: #{Coverband.configuration.track_views ? 'enabled' : 'disabled'}"

# Example coverage collection (this happens automatically in real usage)
if defined?(Rails)
  # This demonstrates that the interface is compatible
  coverage_data = { 'app/models/user.rb' => [1, 0, 1, 1, 0] }
  test_case_id = 'test_user_creation_123'
  
  # This works with both Redis and MySQL stores
  Coverband.configuration.store.save_report(coverage_data, test_case_id)
  puts "Coverage data saved to MySQL successfully"
end 