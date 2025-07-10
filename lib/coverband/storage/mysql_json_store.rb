# frozen_string_literal: true

require_relative '../adapters/base'
require 'connection_pool'
require 'mysql2'

module Coverband
  module Storage
    ##
    # MySQL JSON storage adapter using mysql2 with connection pooling
    # This adapter provides database independence from ActiveRecord
    ##
    class MysqlJsonStore < Coverband::Adapters::Base

      PWD_DIR = Dir.pwd + '/'
      
      def initialize(mysql_config = {})
        super() # Call parent constructor
        
        # Default MySQL configuration with minimal timeout fixes
        config = {
          host: mysql_config[:host] || 'localhost',
          port: mysql_config[:port] || 3306,
          username: mysql_config[:username] || 'root',
          password: mysql_config[:password],
          database: mysql_config[:database] || 'coverband',
          reconnect: true,
          connect_timeout: mysql_config[:connect_timeout] || 10,
          read_timeout: mysql_config[:read_timeout] || 60,
          write_timeout: mysql_config[:write_timeout] || 60
        }.merge(mysql_config)
        
        # Create connection pool
        pool_size = mysql_config[:pool_size] || 10
        pool_timeout = mysql_config[:pool_timeout] || 10
        
        @pool = ConnectionPool.new(size: pool_size, timeout: pool_timeout) do
          Mysql2::Client.new(config)
        end
      end
      
      def connection
        @pool.with do |conn|
          # Simple ping check before use
          conn.ping
          yield(conn)
        end
      rescue Mysql2::Error => e
        Rails.logger&.error("Coverband MySQL: #{e.message}")
        raise
      end

      def clear!
        connection { |client| client.query("TRUNCATE TABLE test_coverage") }
      end
      
      def clear_file!(filename)
        connection do |client|
          # Remove all records containing this file path
          json_path = "$.\"#{filename.gsub('"', '\\"')}\""
          sql = "DELETE FROM test_coverage WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')"
          client.query(sql)
        end
      end
      
      def size
        connection do |client|
          result = client.query("SELECT COUNT(*) as count FROM test_coverage")
          result.first['count']
        end
      end
      
      def coverage(_local_type = nil, opts = {})
        connection do |client|
          # Convert from your format to Coverband's expected format
          sql = "SELECT test_case_id, request_details, file_paths FROM test_coverage"
          results = client.query(sql)
          
          coverage_data = {}
          results.each do |row|
            test_case_id, request_details, file_paths_json = row.values_at('test_case_id', 'request_details', 'file_paths')
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
      end
      
      def save_report(coverage_map, test_case_details = {})
        coverage_map.transform_keys! { |file| file.to_s.gsub(PWD_DIR, '') }
        store_coverage(test_case_details, coverage_map)
      end
      
      
      ##
      # Core storage methods using mysql2 with connection pooling
      ##
      
      def store_coverage(test_case_details, file_paths)
        return false if file_paths.nil? || file_paths.empty?
        
        connection do |client|
          file_paths_json = file_paths.to_json
          test_case_details_json = test_case_details.to_json
          # Use mysql2's escape method for proper escaping
          test_case_id = test_case_details[:test_id] || test_case_details['test_id']
          
          # Validate test_case_id exists
          return false unless test_case_id
          
          escaped_test_case_id = client.escape(test_case_id.to_s)
          escaped_request_details = client.escape(test_case_details_json)
          escaped_file_paths_json = client.escape(file_paths_json)
          
          sql = <<~SQL
            INSERT INTO test_coverage (test_case_id, request_details, file_paths, created_at, updated_at)
            VALUES ('#{escaped_test_case_id}', '#{escaped_request_details}', '#{escaped_file_paths_json}', NOW(), NOW())
            ON DUPLICATE KEY UPDATE 
              file_paths = VALUES(file_paths),
              updated_at = NOW()
          SQL
          
          client.query(sql)
          true
        end
      rescue Mysql2::Error => e
        if defined?(Rails) && Rails.logger
          Rails.logger.error("Coverband MySQL: Error storing coverage: #{e.message}")
          Rails.logger.error("Coverband MySQL: Backtrace: #{e.backtrace.join("\n")}")
        else
          puts "Coverband MySQL: Error storing coverage: #{e.message}"
        end
        false # Don't raise - coverage errors shouldn't break your app
      rescue => e
        if defined?(Rails) && Rails.logger
          Rails.logger.error("Coverband MySQL: Unexpected error storing coverage: #{e.message}")
          Rails.logger.error("Coverband MySQL: Backtrace: #{e.backtrace.join("\n")}")
        else
          puts "Coverband MySQL: Unexpected error storing coverage: #{e.message}"
        end
        false
      end
      
      def find_test_cases_by_file(file_path)
        connection do |client|
          json_path = "$.\"#{file_path.gsub('"', '\\"')}\""
          sql = <<~SQL
            SELECT DISTINCT test_case_id 
            FROM test_coverage 
            WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')
          SQL
          
          results = client.query(sql)
          results.map { |row| row['test_case_id'] }
        end
      end
      
      def find_requests_by_file(file_path)
        connection do |client|
          json_path = "$.\"#{file_path.gsub('"', '\\"')}\""
          sql = <<~SQL
            SELECT DISTINCT request_details 
            FROM test_coverage 
            WHERE JSON_CONTAINS_PATH(file_paths, 'one', '#{json_path}')
          SQL
          
          results = client.query(sql)
          results.map { |row| row['request_details'] }
        end
      end
      
      def find_files_by_test_and_request(test_case_id, request_details)
        connection do |client|
          # Use mysql2 escaping
          escaped_test_case_id = client.escape(test_case_id.to_s)
          escaped_request_details = client.escape(request_details.to_s)
          
          sql = <<~SQL
            SELECT JSON_KEYS(file_paths) as files
            FROM test_coverage 
            WHERE test_case_id = '#{escaped_test_case_id}' AND request_details = '#{escaped_request_details}'
          SQL
          
          result = client.query(sql).first
          return [] unless result && result['files']
          
          JSON.parse(result['files'])
        rescue JSON::ParserError
          []
        end
      end
      
      def get_stats
        connection do |client|
          sql = <<~SQL
            SELECT 
              COUNT(DISTINCT test_case_id) as test_cases,
              COUNT(DISTINCT request_details) as requests,
              COUNT(*) as total_records
            FROM test_coverage
          SQL
          
          result = client.query(sql).first
          {
            test_cases: result['test_cases'],
            requests: result['requests'], 
            total_records: result['total_records']
          }
        end
      end
      
      
      private

      def should_retry?(error)
        # Retry on connection-related errors
        case error.message
        when /Lost connection to MySQL server/,
             /MySQL server has gone away/,
             /Can't connect to MySQL server/,
             /Connection refused/,
             /Timeout/,
             /broken pipe/i,
             /connection reset/i
          true
        else
          false
        end
      end
    end
  end
end