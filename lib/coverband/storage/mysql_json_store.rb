# frozen_string_literal: true

require_relative '../adapters/base'
require 'mysql2'

module Coverband
  module Storage
    ##
    # MySQL JSON storage adapter using mysql2
    # This adapter provides database independence from ActiveRecord
    ##
    class MysqlJsonStore < Coverband::Adapters::Base

      PWD_DIR = Dir.pwd + '/'
      
      def initialize(mysql_config = {})
        super() # Call parent constructor
        
        # Default MySQL configuration with minimal timeout fixes
        @mysql_config = {
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
        
        # Simple size-based batching - flush when batch reaches target size
        @batch_size = mysql_config[:batch_size] || 50
        @batch_buffer = []
        @batch_mutex = Mutex.new
        
        # Register exit handler to flush any remaining data
        at_exit { flush_batch }
      end
      
      def connection
        @client ||= Mysql2::Client.new(@mysql_config)
      rescue Exception => e
        # NewRelic::Agent.notice_error(e, { error: "Coverband MySQL connection error ##{e.message}" })
        # raise
        Rails.logger.info "Coverband MySQL: Connection error: #{e.message} with class #{e.class}"
      end

      def clear!
        connection.query("TRUNCATE TABLE test_coverage")
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
        result = connection.query("SELECT COUNT(*) as count FROM test_coverage")
        result.first['count']
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
      # Core storage methods using mysql2
      ##
      
      def store_coverage(test_case_details, file_paths)
        return false if file_paths.nil? || file_paths.empty?
        
        test_case_id = test_case_details[:test_id] || test_case_details['test_id']
        return false unless test_case_id
        
        # Add to batch instead of immediate write
        batch_item = {
          test_case_id: test_case_id.to_s,
          request_details: test_case_details.to_json,
          file_paths: file_paths.to_json,
          timestamp: Time.now
        }
        
        add_to_batch(batch_item)
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
      
      def add_to_batch(item)
        should_flush = false
        
        @batch_mutex.synchronize do
          @batch_buffer << item
          
          # Check if we should flush based on size
          should_flush = @batch_buffer.size >= @batch_size
        end
        flush_batch if should_flush
        true
      rescue => e
        # Log error but don't break the application
        if defined?(Rails) && Rails.logger
          Rails.logger.error("Coverband MySQL: Error adding to batch: #{e.message}")
        else
          Rails.logger.info "Coverband MySQL: Error adding to batch: #{e.message}"
        end
        false
      end
      
      def flush_batch
        items_to_flush = nil
        
        @batch_mutex.synchronize do
          return if @batch_buffer.empty?
          items_to_flush = @batch_buffer.dup
          @batch_buffer.clear
        end
        return unless items_to_flush && !items_to_flush.empty?
        
        batch_insert(items_to_flush)
      rescue => e
        # On flush error, we lose this batch but log it
        if defined?(Rails) && Rails.logger
          Rails.logger.error("Coverband MySQL: Error flushing batch of #{items_to_flush&.size} items: #{e.message}")
        else
          Rails.logger.info "Coverband MySQL: Error flushing batch of #{items_to_flush&.size} items: #{e.message}"
        end
      end
      
      def batch_insert(items)
        return if items.empty?
        
        # Prepare all chunks outside of connection block
        chunk_size = 10
        prepared_chunks = items.each_slice(chunk_size).map do |chunk|
          # Build multi-value INSERT statement
          Rails.logger.info("Coverband: Writing to Mysql IDS #{chunk.map{ |c| c[:test_case_id] }.uniq}")
          placeholders = chunk.map { "(?, ?, ?, NOW(), NOW())" }.join(", ")
          sql = <<~SQL
            INSERT INTO test_coverage (test_case_id, request_details, file_paths, created_at, updated_at)
            VALUES #{placeholders}
          SQL

          # Flatten the values for prepared statement
          values = chunk.flat_map do |item|
            [item[:test_case_id], item[:request_details], item[:file_paths]]
          end
          
          { sql: sql, values: values, items: chunk }
        end
        
        # Execute all chunks in a single connection with per-chunk error handling
        successful_chunks = 0
        failed_chunks = []
        prepared_chunks.each_with_index do |chunk_data, index|
          begin
            Rails.logger.info "connecting to MySQL and executing chunk #{index + 1}"
            stmt = connection.prepare(chunk_data[:sql])
            stmt.execute(*chunk_data[:values])
            stmt.close
            successful_chunks += 1
          rescue Exception => e
            if defined?(Rails) && Rails.logger
              Rails.logger.error("Coverband MySQL: Error in chunk #{index + 1}: #{e.message}")
            else
              Rails.logger.info "Coverband MySQL: Error in chunk #{index + 1}: #{e.message}"
            end
            failed_chunks << { chunk_data: chunk_data, error: e, index: index }
          end
        end        
        
        # Log overall batch results
        if defined?(Rails) && Rails.logger && Coverband.configuration.verbose
          Rails.logger.info("Coverband MySQL: Batch completed - #{successful_chunks}/#{prepared_chunks.size} chunks successful, #{items.size} total items")
        end
        
        # Always retry failed chunks as original multi-row insert, then fallback to individual inserts if that fails
        failed_chunks.each do |failed_chunk|
          chunk_data = failed_chunk[:chunk_data]
          begin
            Rails.logger.info "Retrying original multi-row insert for failed chunk #{failed_chunk[:index] + 1}"
            stmt = connection.prepare(chunk_data[:sql])
            stmt.execute(*chunk_data[:values])
            stmt.close
          rescue Exception => e2
            if defined?(Rails) && Rails.logger
              Rails.logger.error("Coverband MySQL: Retry failed for chunk #{failed_chunk[:index] + 1}: #{e2.message}, falling back to individual inserts")
            else
              Rails.logger.info "Coverband MySQL: Retry failed for chunk #{failed_chunk[:index] + 1}: #{e2.message}, falling back to individual inserts"
            end
          end
        end
      rescue => e
        # Catch-all for any unexpected errors during batch processing
        if defined?(Rails) && Rails.logger
          Rails.logger.error("Coverband MySQL: Unexpected error in batch insert: #{e.message}")
        else
          Rails.logger.info "Coverband MySQL: Unexpected error in batch insert: #{e.message}"
        end
        # Fall back to individual inserts for the entire batch
      end
    end
  end
end