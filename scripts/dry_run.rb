#!/usr/bin/env ruby

# Auto-install required gems if not available
begin
  require 'octokit'
rescue LoadError
  puts "Installing required gems..."
  require 'bundler/inline'
  
  gemfile do
    source 'https://rubygems.org'
    gem 'octokit'
  end
  puts "Gems installed successfully!"
end

require 'json'
require 'fileutils'
require 'mysql2' # for RDS MySQL connection

class PRCoverageAnalyzer
  def initialize(github_token, rds_config = {})
    @github_client = Octokit::Client.new(access_token: github_token)
    @rds_config = rds_config
  end

  # 1. Find pull requests in freshdesk/itildesk repo with base branch 'prestaging'
  def fetch_pull_requests(repo = 'freshdesk/itildesk', base_branch = 'prestaging', limit = 30)
    puts "Fetching pull requests from #{repo} with base branch: #{base_branch}"
    
    # Fetch pull requests with the specified base branch
    pull_requests = @github_client.pull_requests(repo, 
      state: 'all', 
      base: base_branch,
      per_page: limit
    )
    
    puts "Found #{pull_requests.size} pull requests"
    
    # Return simplified PR data
    pull_requests.map do |pr|
      {
        number: pr.number,
        title: pr.title,
        state: pr.state,
        created_at: pr.created_at,
        updated_at: pr.updated_at,
        head_sha: pr.head.sha,
        base_sha: pr.base.sha
      }
    end
  rescue Octokit::Error => e
    puts "Error fetching pull requests: #{e.message}"
    []
  end

  # 2. For each PR, get the list of Ruby files that are added/deleted/modified
  def get_changed_ruby_files(repo, pr_number)
    puts "Fetching changed Ruby files for PR ##{pr_number}"
    
    # Get the files changed in the PR
    files = @github_client.pull_request_files(repo, pr_number)
    
    # Filter for Ruby files only
    ruby_files = filter_ruby_files(files)
    
    puts "Found #{ruby_files.size} Ruby files changed"
    
    # Return file information with status
    ruby_files.map do |file|
      {
        filename: file.filename,
        status: file.status, # 'added', 'modified', 'removed'
        additions: file.additions,
        deletions: file.deletions,
        changes: file.changes
      }
    end
  rescue Octokit::Error => e
    puts "Error fetching files for PR ##{pr_number}: #{e.message}"
    []
  end

  # 3. Query RDS instance to get impacted test cases for the changed files
  def get_impacted_test_cases(changed_files)
    puts "Querying coverage map for impacted test cases"
    
    return [] if changed_files.empty?
    
    connection = connect_to_mysql
    return [] unless connection
    
    begin
      # Test connection first
      connection.query("SELECT 1 as test_connection")
      puts "MySQL connection successful!"
      
      # Query for impacted test cases
      impacted_tests = query_coverage_data(connection, changed_files)
      puts "Found #{impacted_tests.size} impacted test cases"
      
      impacted_tests
      
    rescue Mysql2::Error => e
      puts "MySQL query error: #{e.message}"
      []
    ensure
      connection&.close
    end
  end

  # Main method to orchestrate the analysis
  def analyze_coverage_impact
    puts "Starting PR coverage analysis..."
    
    # Step 1: Get PRs
    pull_requests = fetch_pull_requests
    
    results = {}
    
    # Step 2 & 3: For each PR, get changed files and impacted tests
    pull_requests.each do |pr|
      puts "\n--- Analyzing PR ##{pr[:number]}: #{pr[:title]} ---"
      
      changed_files = get_changed_ruby_files('freshdesk/itildesk', pr[:number])
      
      if changed_files.any?
        puts "Changed files: #{changed_files.map { |f| f[:filename] }.join(', ')}"
        
        impacted_tests = get_impacted_test_cases(changed_files)
        
        # Structure the results as requested
        results[pr[:number]] = {
          pr_info: {
            title: pr[:title],
            state: pr[:state],
            changed_files: changed_files.map { |f| f[:filename] }
          },
          test_cases: group_test_cases_by_id(impacted_tests)
        }
        
        puts "PR ##{pr[:number]} affects #{impacted_tests.size} test cases"
      else
        puts "No Ruby files changed in PR ##{pr[:number]}"
      end
    end
    
    # Write results to JSON file
    write_results_to_json(results)
    
    print_structured_summary(results)
    results
  end

  private

  def connect_to_mysql
    return nil if @rds_config.empty?
    
    puts "Connecting to MySQL RDS..."
    puts "Host: #{@rds_config[:host]}"
    puts "Database: #{@rds_config[:database]}"
    
    Mysql2::Client.new(
      host: @rds_config[:host],
      port: @rds_config[:port] || 3306,
      database: @rds_config[:database],
      username: @rds_config[:username],
      password: @rds_config[:password],
      connect_timeout: 10,
      read_timeout: 30,
      write_timeout: 30,
      reconnect: false
    )
  rescue Mysql2::Error => e
    puts "Failed to connect to MySQL: #{e.message}"
    nil
  rescue => e
    puts "Unexpected error connecting to MySQL: #{e.class} - #{e.message}"
    nil
  end

  def filter_ruby_files(files)
    files.select { |file| file[:filename].end_with?('.rb') }
  end

  def query_coverage_data(connection, changed_files)
    # Extract file paths from changed files
    file_paths = changed_files.map { |file| normalize_file_path(file[:filename]) }
    
    puts "Querying for files: #{file_paths.join(', ')}"
    
    # Build the query to find test cases that cover any of these files
    # Using JSON_EXTRACT to check if file paths exist as keys in the JSON
    conditions = file_paths.map { |path| "JSON_EXTRACT(file_paths, '$.\"#{path}\"') IS NOT NULL" }
    where_clause = conditions.join(' OR ')
    
    query = <<-SQL
      SELECT 
        id,
        test_case_id,
        request_details,
        file_paths,
        created_at,
        updated_at
      FROM test_coverage 
      WHERE #{where_clause}
      ORDER BY test_case_id;
    SQL
    
    puts "Executing query..."
    result = connection.query(query)
    
    # Process results
    test_cases = []
    result.each do |row|
      file_paths_json = JSON.parse(row['file_paths'])
      request_details = JSON.parse(row['request_details'])
      
      # Find which of our changed files are covered by this test case
      covered_files = file_paths.select { |path| file_paths_json.key?(path) }
      
      test_cases << {
        id: row['id'],
        test_case_id: row['test_case_id'],
        action_url: request_details['action_url'],
        action_type: request_details['action_type'],
        covered_files: covered_files,
        total_files_covered: file_paths_json.keys.size,
        created_at: row['created_at'],
        updated_at: row['updated_at']
      }
    end
    
    test_cases
  rescue JSON::ParserError => e
    puts "JSON parsing error: #{e.message}"
    []
  end

  def normalize_file_path(github_path)
    # GitHub paths don't have leading slash, but DB paths do
    # Convert "app/models/user.rb" to "/app/models/user.rb"
    github_path.start_with?('/') ? github_path : "/#{github_path}"
  end

  def group_test_cases_by_id(impacted_tests)
    grouped = {}
    
    impacted_tests.each do |test_case|
      test_case_id = test_case[:test_case_id]
      
      # Initialize the test case entry if it doesn't exist
      unless grouped[test_case_id]
        grouped[test_case_id] = {
          requests: []
        }
      end
      
      # Add the request details to the requests array
      grouped[test_case_id][:requests] << {
        id: test_case[:id],
        action_url: test_case[:action_url],
        action_type: test_case[:action_type],
        covered_files: test_case[:covered_files],
        total_files_covered: test_case[:total_files_covered],
        created_at: test_case[:created_at],
        updated_at: test_case[:updated_at]
      }
    end
    
    grouped
  end

  def print_structured_summary(results)
    puts "\n" + "="*60
    puts "STRUCTURED SUMMARY"
    puts "="*60
    
    total_prs = results.size
    total_test_cases = results.sum { |_, pr_data| pr_data[:test_cases].size }
    total_requests = results.sum { |_, pr_data| 
      pr_data[:test_cases].sum { |_, test_case| test_case[:requests].size }
    }
    
    puts "Total PRs analyzed: #{total_prs}"
    puts "Total unique test cases: #{total_test_cases}"
    puts "Total request entries: #{total_requests}"
    
    # Show example structure
    puts "\nExample structure:"
    first_pr = results.first
    if first_pr
      pr_number, pr_data = first_pr
      puts "PR ##{pr_number}: #{pr_data[:pr_info][:title]}"
      puts "  Changed files: #{pr_data[:pr_info][:changed_files].join(', ')}"
      puts "  Test cases: #{pr_data[:test_cases].size}"
      
      # Show first test case as example
      first_test_case = pr_data[:test_cases].first
      if first_test_case
        test_case_id, test_case_data = first_test_case
        puts "    Test case #{test_case_id}: #{test_case_data[:requests].size} requests"
      end
    end
    
    puts "\nAccess pattern:"
    puts "results[pr_number][:test_cases][test_case_id][:requests] # Array of request details"
  end

  def write_results_to_json(results)
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    filename = "pr_coverage_analysis_#{timestamp}.json"
    filepath = File.join('tmp', filename)
    
    puts "\nWriting results to #{filepath}..."
    
    # Ensure tmp directory exists (it should already exist in the workspace)
    FileUtils.mkdir_p('tmp') unless Dir.exist?('tmp')
    
    # Convert results to JSON-friendly format (handle Time objects)
    json_results = convert_to_json_format(results)
    
    File.write(filepath, JSON.pretty_generate(json_results))
    puts "Results written to #{filepath}"
    
    filepath
  end

  def convert_to_json_format(results)
    results.transform_values do |pr_data|
      {
        pr_info: pr_data[:pr_info],
        test_cases_count: pr_data[:test_cases].size,
        test_cases: pr_data[:test_cases].transform_values do |test_case|
          {
            requests: test_case[:requests].map do |request|
              request.transform_values do |value|
                # Convert Time objects to ISO 8601 strings
                value.is_a?(Time) ? value.iso8601 : value
              end
            end
          }
        end
      }
    end
  end
end

db_config = YAML::load_file(File.join(Rails.root, 'config', 'database.yml'))[Rails.env]
stagingrds5_config = {
  host: db_config['host'],
  username: db_config['username'],
  password: db_config['password'],
  database: db_config['database'],
  port: db_config['port']
}