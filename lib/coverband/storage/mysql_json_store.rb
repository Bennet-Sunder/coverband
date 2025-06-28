# frozen_string_literal: true

require_relative '../adapters/base'

module Coverband
  module Storage
    ##
    # MySQL JSON storage adapter that integrates with Coverband's existing architecture
    # This adapter converts between Coverband's expected format and your JSON storage needs
    ##
    class MysqlJsonStore < Coverband::Adapters::Base
      attr_reader :mysql_client
      
      def initialize(mysql_config = {})
        super() # Call parent constructor
        require 'mysql2'
        
        @mysql_client = Mysql2::Client.new(
          host: mysql_config[:host] || 'localhost',
          username: mysql_config[:username] || 'root',
          password: mysql_config[:password] || nil,  # No password for local root
          database: mysql_config[:database] || 'itildesk1',
          port: mysql_config[:port] || 3306
        )
      end
      
      ##
      # Coverband compatibility methods - these are required by the base adapter
      ##
      
      def clear!
        @mysql_client.query("TRUNCATE TABLE test_coverage")
      end
      
      def clear_file!(filename)
        # Remove all records containing this file path
        sql = "DELETE FROM test_coverage WHERE JSON_CONTAINS_PATH(file_paths, 'one', ?)"
        stmt = @mysql_client.prepare(sql)
        stmt.execute("$.\"#{escape_json_key(filename)}\"")
      end
      
      def size
        result = @mysql_client.query("SELECT COUNT(*) as count FROM test_coverage")
        result.first['count']
      end
      
      def coverage(_local_type = nil, opts = {})
        # Convert from your format to Coverband's expected format
        # This is a simplified conversion - you may need to enhance based on usage
        sql = "SELECT test_case_id, request_details, file_paths FROM test_coverage"
        results = @mysql_client.query(sql)
        
        coverage_data = {}
        results.each do |row|
          files = JSON.parse(row['file_paths'])
          files.each_key do |file_path|
            coverage_data[file_path] = {
              "data" => [1], # Simplified - you'd need real coverage data
              "first_updated_at" => Time.now.to_i,
              "last_updated_at" => Time.now.to_i
            }
          end
        end
        coverage_data
      end
      
      def save_report(coverage_map, test_case_details = {})
        # Convert Coverband's report format to your storage format
        # This is where you'd extract test case and request info from the context
        
        # Extract test case information
        test_id = test_case_details[:test_id]
        action_type = test_case_details[:action_type]
        action_url = test_case_details[:action_url]
        response_code = test_case_details[:response_code]

        request_details = "#{action_type || 'UNKNOWN'}::#{action_url || 'UNKNOWN'}::#{response_code || 'UNKNOWN'}"
        
        store_coverage(test_id, request_details, coverage_map)
      end
      
      
      ##
      # Your original methods for JSON-based queries
      ##
      
      def store_coverage(test_case_id, request_details, file_paths)
        sql = <<~SQL
          INSERT INTO test_coverage (test_case_id, request_details, file_paths)
          VALUES (?, ?, ?)
          ON DUPLICATE KEY UPDATE 
            file_paths = VALUES(file_paths),
            updated_at = CURRENT_TIMESTAMP
        SQL
        
        @mysql_client.prepare(sql).execute(
          test_case_id, 
          request_details, 
          file_paths.to_json
        )
      end
      
      def batch_store_coverage(coverage_data)
        return 0 unless coverage_data.is_a?(Hash)
        
        count = 0
        coverage_data.each do |test_case_id, requests|
          next unless requests.is_a?(Hash)
          
          requests.each do |request_details, files|
            next unless files.is_a?(Hash)
            
            store_coverage(test_case_id, request_details, files)
            count += 1
          end
        end
        count
      end
      
      def find_test_cases_by_file(file_path)
        sql = <<~SQL
          SELECT DISTINCT test_case_id 
          FROM test_coverage 
          WHERE JSON_CONTAINS_PATH(file_paths, 'one', ?)
        SQL
        
        stmt = @mysql_client.prepare(sql)
        results = stmt.execute("$.\"#{escape_json_key(file_path)}\"")
        results.map { |row| row['test_case_id'] }
      end
      
      def find_requests_by_file(file_path)
        sql = <<~SQL
          SELECT DISTINCT request_details 
          FROM test_coverage 
          WHERE JSON_CONTAINS_PATH(file_paths, 'one', ?)
        SQL
        
        stmt = @mysql_client.prepare(sql)
        results = stmt.execute("$.\"#{escape_json_key(file_path)}\"")
        results.map { |row| row['request_details'] }
      end
      
      def find_files_by_test_and_request(test_case_id, request_details)
        sql = <<~SQL
          SELECT JSON_KEYS(file_paths) as files
          FROM test_coverage 
          WHERE test_case_id = ? AND request_details = ?
        SQL
        
        stmt = @mysql_client.prepare(sql)
        result = stmt.execute(test_case_id, request_details).first
        
        return [] unless result && result['files']
        JSON.parse(result['files'])
      end
      
      def get_stats
        sql = <<~SQL
          SELECT 
            COUNT(DISTINCT test_case_id) as test_cases,
            COUNT(DISTINCT request_details) as requests,
            COUNT(*) as total_records
          FROM test_coverage
        SQL
        
        @mysql_client.query(sql).first
      end
      
      def close
        @mysql_client&.close
      end
      
      private
      
      def escape_json_key(key)
        key.gsub('\\', '\\\\').gsub('"', '\\"')
      end
      
      def extract_test_case_id
        # Extract from thread-local storage, request context, etc.
        Thread.current[:coverband_test_case_id] ||
        ENV['COVERBAND_TEST_CASE_ID'] ||
        "test_#{Time.now.to_i}"
      end
      
      def extract_request_details
        # Extract from Rack env, Rails request, etc.
        if defined?(Rails) && Rails.application
          request = Thread.current[:current_request]
          if request
            "#{request.method}::#{request.path}::#{request.status || 'unknown'}"
          else
            "background_job::#{Time.now.to_i}"
          end
        else
          "request_#{Time.now.to_i}"
        end
      end
      
      def generate_request_details_from_data(data)
        # Generate request details string from test case data from BackgroundMiddleware
        return "unknown_request" unless data && data.is_a?(Hash)
        
        action_type = data[:action_type] || data['action_type'] || 'UNKNOWN'
        action_url = data[:action_url] || data['action_url'] || 'unknown-url'
        response_code = data[:response_code] || data['response_code'] || 'unknown'
        
        # Create a detailed request string (up to 2000 chars)
        "#{action_type}::#{action_url}::#{response_code}::#{Time.now.to_i}"
      end
    end
  end
end