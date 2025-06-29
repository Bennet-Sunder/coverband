# frozen_string_literal: true

require_relative '../adapters/base'

module Coverband
  module Storage
    ##
    # MySQL JSON storage adapter using ActiveRecord's connection
    # This adapter integrates with Coverband's existing architecture
    ##
    class MysqlJsonStore < Coverband::Adapters::Base
      
      def initialize(_mysql_config = {})
        super() # Call parent constructor
      end
      
      def connection
        ActiveRecord::Base.connection
      end
      

      def clear!
        connection.execute("TRUNCATE TABLE test_coverage")
      end
      
      def clear_file!(filename)
        # Remove all records containing this file path
        json_path = "$.\"#{filename.gsub('"', '\\"')}\""
        sql = "DELETE FROM test_coverage WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')"
        connection.execute(sql)
      end
      
      def size
        result = connection.execute("SELECT COUNT(*) as count FROM test_coverage")
        result.first[0] # First row, first column
      end
      
      def coverage(_local_type = nil, opts = {})
        # Convert from your format to Coverband's expected format
        sql = "SELECT test_case_id, request_details, file_paths FROM test_coverage"
        results = connection.execute(sql)
        
        coverage_data = {}
        results.each do |row|
          # ActiveRecord returns arrays, so access by index
          test_case_id, request_details, file_paths_json = row
          files = JSON.parse(file_paths_json)
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
      # Core storage methods using ActiveRecord connection
      ##
      
      def store_coverage(test_case_id, request_details, file_paths)
        file_paths_json = file_paths.to_json
        
        # Use connection.execute with proper escaping like other methods in this class
        escaped_test_case_id = connection.quote(test_case_id)
        escaped_request_details = connection.quote(request_details)
        escaped_file_paths_json = connection.quote(file_paths_json)
        
        sql = <<~SQL
          INSERT INTO test_coverage (test_case_id, request_details, file_paths, created_at, updated_at)
          VALUES (#{escaped_test_case_id}, #{escaped_request_details}, #{escaped_file_paths_json}, NOW(), NOW())
          ON DUPLICATE KEY UPDATE 
            file_paths = VALUES(file_paths),
            updated_at = NOW()
        SQL
        
        connection.execute(sql)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.error("Coverband MySQL: Error storing coverage: #{e.message}")
        raise e
      end
      
      def find_test_cases_by_file(file_path)
        json_path = "$.\"#{file_path.gsub('"', '\\"')}\""
        sql = <<~SQL
          SELECT DISTINCT test_case_id 
          FROM test_coverage 
          WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')
        SQL
        
        results = connection.execute(sql)
        results.map { |row| row[0] } # Extract first column from each row
      end
      
      def find_requests_by_file(file_path)
        json_path = "$.\"#{file_path.gsub('"', '\\"')}\""
        sql = <<~SQL
          SELECT DISTINCT request_details 
          FROM test_coverage 
          WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')
        SQL
        
        results = connection.execute(sql)
        results.map { |row| row[0] } # Extract first column from each row
      end
      
      def find_files_by_test_and_request(test_case_id, request_details)
        # Use string interpolation with proper escaping for active_record_shards compatibility
        escaped_test_case_id = connection.quote(test_case_id)
        escaped_request_details = connection.quote(request_details)
        
        sql = <<~SQL
          SELECT JSON_KEYS(file_paths) as files
          FROM test_coverage 
          WHERE test_case_id = #{escaped_test_case_id} AND request_details = #{escaped_request_details}
        SQL
        
        result = connection.execute(sql).first
        return [] unless result && result[0]
        
        JSON.parse(result[0])
      rescue JSON::ParserError
        []
      end
      
      def get_stats
        sql = <<~SQL
          SELECT 
            COUNT(DISTINCT test_case_id) as test_cases,
            COUNT(DISTINCT request_details) as requests,
            COUNT(*) as total_records
          FROM test_coverage
        SQL
        
        result = connection.execute(sql).first
        {
          test_cases: result[0],
          requests: result[1], 
          total_records: result[2]
        }
      end
      
      
      private

    end
  end
end