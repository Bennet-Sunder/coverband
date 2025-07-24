# frozen_string_literal: true

# Coverband MySQL Configuration Example
# This replaces Redis storage with MySQL JSON storage
#
# Place this file in config/initializers/coverband.rb (for Rails apps)
# or require it in your application configuration

Coverband.configure do |config|
  # Use MySQL JSON storage instead of Redis
  config.store = Coverband::Storage::MysqlJsonStore.new(
    # MySQL connection config - uses Rails database connection by default
    # Optionally specify custom database config:
    # host: 'localhost',
    # database: 'your_database',
    # username: 'your_username',
    # password: 'your_password',
    
    # Batching configuration for performance
    batch_size: 50,  # Number of coverage records to batch before writing
    chunk_size: 10   # Size of chunks for bulk insert operations
  )
  
  # Keep existing coverage tracking settings
  config.track_views = true
  config.track_routes = true
  config.track_translations = true
  
  # Coverage collection settings
  config.coverage_baseline_file = './tmp/coverband_baseline.json'
  config.root_paths = [Dir.pwd]
  config.ignore = [
    'vendor/',
    'spec/',
    'test/',
    'config/initializers/coverband.rb'
  ]
  
  # Enable method-level tracing (keep existing functionality)
  config.track_views = true
  config.use_oneshot_lines_coverage = true
  
  if Rails.env.production?
    config.background_reporting_enabled = true
    config.background_reporting_sleep_seconds = 30
  end
end

# Note: Ensure your database has the test_coverage table:
# 
# CREATE TABLE test_coverage (
#   id BIGINT AUTO_INCREMENT PRIMARY KEY,
#   test_case_id VARCHAR(255) NOT NULL,
#   request_details JSON NOT NULL,
#   file_paths JSON NOT NULL,
#   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#   updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
#   INDEX idx_test_case_id (test_case_id),
#   INDEX idx_file_paths_mv ((CAST(file_paths->'$[*]' AS CHAR(255) ARRAY)))
# ); 