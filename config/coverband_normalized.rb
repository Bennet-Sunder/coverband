# frozen_string_literal: true

# Coverband Normalized MySQL Configuration
# This configuration uses the recommended normalized schema approach
# Optimized for fast writes, batched writes, and fast queries

Coverband.configure do |config|
  # Use the new normalized MySQL storage instead of JSON storage
  config.store = Coverband::Storage::NormalizedMysqlStore.new(
    # Optimized batching configuration for high write volume
    batch_size: 200,    # Increased from default 50 for better throughput
    chunk_size: 50,     # Increased from default 10 for efficient bulk inserts
    
    # Optional: Custom database configuration (defaults to Rails connection)
    # host: 'your-mysql-host',
    # database: 'your_database',
    # username: 'your_username',
    # password: 'your_password',
    
    # Performance tuning options
    cache_enabled: true,  # Enable in-memory caching for frequently accessed data
    connection_pool_size: 10  # Optimize for concurrent access
  )
  
  # Enhanced coverage tracking settings
  config.track_views = true
  config.track_routes = true
  config.track_translations = true
  
  # Method-level coverage for detailed impact analysis
  config.use_oneshot_lines_coverage = true
  
  # Coverage collection optimization
  config.coverage_baseline_file = './tmp/coverband_baseline.json'
  config.root_paths = [Dir.pwd]
  
  # Optimized ignore patterns - exclude non-essential files
  config.ignore = [
    'vendor/',
    'spec/',
    'test/',
    'db/migrate/',
    'config/initializers/coverband.rb',
    'node_modules/',
    'public/',
    'tmp/',
    'log/',
    '*.log'
  ]
  
  # Environment-specific optimizations
  if Rails.env.development?
    # Reduced reporting frequency for development
    config.background_reporting_enabled = false
    config.verbose = true
    
  elsif Rails.env.test?
    # Optimized for test suite performance
    config.background_reporting_enabled = false
    config.verbose = false
    
  elsif Rails.env.production?
    # Production optimizations
    config.background_reporting_enabled = true
    config.background_reporting_sleep_seconds = 60  # Increased for production
    config.verbose = false
    
    # Production-specific ignore patterns
    config.ignore.concat([
      'lib/tasks/',
      'app/admin/',
      'config/deploy/',
      'script/'
    ])
  end
end

# Performance monitoring and alerting hooks
if Rails.env.production?
  # Hook into Coverband reporting for performance monitoring
  Coverband.configuration.store.extend(Module.new do
    def flush_batch
      start_time = Time.current
      result = super
      duration = Time.current - start_time
      
      # Alert if batch writing is taking too long
      if duration > 5.seconds
        Rails.logger.warn("Coverband: Slow batch write detected: #{duration}s")
        # Add your alerting logic here (e.g., send to monitoring service)
      end
      
      result
    end
    
    def find_impacted_tests(file_paths: [], method_names: [])
      start_time = Time.current
      result = super
      duration = Time.current - start_time
      
      # Monitor query performance
      if duration > 1.second
        Rails.logger.warn("Coverband: Slow impact query detected: #{duration}s")
        Rails.logger.warn("  File paths: #{file_paths.size}, Method names: #{method_names.size}")
      end
      
      result
    end
  end)
end

# Integration with your test impact prediction system
module TestImpactIntegration
  # Enhanced impact analysis using the normalized storage
  def self.analyze_pr_impact(pr_numbers)
    analyzer = Coverband::Utils::EnhancedPrAnalyzer.new
    
    # Get PR changes with standardized method names
    pr_changes = analyzer.analyze_pr_changes(pr_numbers)
    
    # Find impacted tests using fast normalized queries
    impacted_tests = analyzer.find_impacted_tests(pr_changes)
    
    # Generate comprehensive report
    {
      timestamp: Time.current.iso8601,
      pr_numbers: pr_numbers,
      changes: pr_changes,
      impacted_tests: impacted_tests,
      performance_stats: gather_performance_stats(pr_changes, impacted_tests)
    }
  end
  
  def self.gather_performance_stats(pr_changes, impacted_tests)
    {
      files_analyzed: pr_changes.values.flat_map(&:keys).uniq.size,
      methods_analyzed: pr_changes.values.flat_map { |changes| 
        changes.values.flat_map(&:values) 
      }.flatten.uniq.size,
      total_impacted_tests: impacted_tests.values
                                       .flat_map { |data| data[:impacted_test_cases] }
                                       .uniq.size,
      coverage_efficiency: calculate_coverage_efficiency(pr_changes, impacted_tests)
    }
  end
  
  def self.calculate_coverage_efficiency(pr_changes, impacted_tests)
    total_methods = pr_changes.values.flat_map { |changes| 
      changes.values.flat_map(&:values) 
    }.flatten.uniq.size
    
    return 0 if total_methods == 0
    
    methods_with_tests = impacted_tests.values.count { |data| data[:test_case_count] > 0 }
    
    (methods_with_tests.to_f / total_methods * 100).round(2)
  end
end

# Example usage in your CI/CD pipeline:
#
# # In your CI script:
# impact_report = TestImpactIntegration.analyze_pr_impact([31475, 32162])
# 
# puts "Impact Analysis Results:"
# puts "Files changed: #{impact_report[:performance_stats][:files_analyzed]}"
# puts "Methods changed: #{impact_report[:performance_stats][:methods_analyzed]}"
# puts "Tests to run: #{impact_report[:performance_stats][:total_impacted_tests]}"
# puts "Coverage efficiency: #{impact_report[:performance_stats][:coverage_efficiency]}%"
#
# # Run only the impacted tests instead of full suite
# impacted_test_ids = impact_report[:impacted_tests].values
#                                                   .flat_map { |data| data[:impacted_test_cases] }
#                                                   .uniq
# 
# if impacted_test_ids.any?
#   puts "Running #{impacted_test_ids.size} impacted test cases..."
#   # Your test execution logic here
# else
#   puts "No test impacts detected, running smoke tests only"
# end

# Database maintenance and optimization
if Rails.env.production?
  # Schedule regular maintenance tasks
  # These could be run via cron or your job scheduler
  
  # Daily: Clean up old coverage data (keep last 30 days)
  # 0 2 * * * cd /path/to/app && rails runner "
  #   TestCoverage.joins(:test_case)
  #              .where('test_cases.created_at < ?', 30.days.ago)
  #              .delete_all
  # "
  
  # Weekly: Optimize database tables
  # 0 3 * * 0 cd /path/to/app && rails runner "
  #   ActiveRecord::Base.connection.execute('OPTIMIZE TABLE test_cases, files, methods, test_coverage')
  # "
  
  # Monthly: Generate coverage analytics report
  # 0 4 1 * * cd /path/to/app && rails runner "
  #   CoverageAnalytics.generate_monthly_report
  # "
end

# Note: Ensure your database has the normalized schema by running:
# mysql -u your_username -p your_database < db/create_normalized_coverage_schema.sql 