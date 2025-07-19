# frozen_string_literal: true

require_relative '../adapters/base'

module Coverband
  module Storage
    ##
    # ActiveRecord-based MySQL JSON storage adapter with array optimization
    # Uses Rails' connection pooling for thread safety - works perfectly with Sidekiq
    # No need for custom connection management since ActiveRecord handles it
    ##
    class MysqlJsonStore < Coverband::Adapters::Base

      PWD_DIR = Dir.pwd + '/'
      
      def initialize(mysql_config = {})
        super() # Call parent constructor
        
        # Store configuration for potential direct queries
        @mysql_config = mysql_config
        
        # Optimized batching configuration
        @batch_size = mysql_config[:batch_size] || 50
        @chunk_size = mysql_config[:chunk_size] || 10  # Can be larger with ActiveRecord
        @batch_buffer = []
        @batch_mutex = Mutex.new
        
        # Ensure the ActiveRecord model is available
        define_test_coverage_model
        
        # Register exit handler to flush any remaining data
        at_exit { flush_batch }
      end
      
      def save_report(coverage_map, test_case_details = {})
        coverage_map.transform_keys! { |file| file.to_s.gsub(PWD_DIR, '') }
        store_coverage(test_case_details, coverage_map)
      end
      
      def store_coverage(test_case_details, file_paths_hash)
        return false if file_paths_hash.nil? || file_paths_hash.empty?
        
        test_case_id = test_case_details[:test_id] || test_case_details['test_id']
        return false unless test_case_id
        
        # Convert hash to array (key optimization)
        file_paths_array = file_paths_hash.keys
        
        # Add to batch instead of immediate write
        batch_item = {
          test_case_id: test_case_id.to_s,
          request_details: test_case_details,  # ActiveRecord handles JSON serialization
          file_paths: file_paths_array,               # ActiveRecord handles JSON serialization
          timestamp: Time.now
        }
        
        add_to_batch(batch_item)
      end
      
      private
      
      def define_test_coverage_model
        # Define the ActiveRecord model dynamically if not already defined
        return if defined?(::TestCoverage)
        
        # Create the model class in the global namespace
        model_class = Class.new(ActiveRecord::Base) do
          self.table_name = 'test_coverage'
          
          # ActiveRecord will handle JSON serialization automatically
          # if the column type is JSON in the database
          
          validates :test_case_id, presence: true
          validates :request_details, presence: true
          validates :file_paths, presence: true
          
          # Use bulk insert for better performance
          def self.bulk_insert(records)
            insert_all(records) if records.any?
          end
        end
        
        # Assign to global constant
        Object.const_set(:TestCoverage, model_class)
      end
      
      def add_to_batch(item)
        should_flush = false
        
        @batch_mutex.synchronize do
          @batch_buffer << item
          should_flush = @batch_buffer.size >= @batch_size
        end
        
        flush_batch if should_flush
        true
      rescue => e
        Rails.logger.error("Coverband MySQL: Error adding to batch: #{e.message}")
        false
      end
      
      def flush_batch
        items_to_flush = nil
        
        @batch_mutex.synchronize do
          return if @batch_buffer.empty?
          items_to_flush = @batch_buffer.dup
          @batch_buffer.clear
        end
				puts "items_to_flush is #{items_to_flush.inspect}"
        return unless items_to_flush && !items_to_flush.empty?
        
        # Use ActiveRecord's connection pooling - thread-safe by default
        batch_insert_with_activerecord(items_to_flush)
      rescue => e
        Rails.logger.error("Coverband MySQL: Error flushing batch of #{items_to_flush&.size} items: #{e.message}")
      end
      
      def batch_insert_with_activerecord(items)
        return if items.empty?
        
        # Process in chunks for memory efficiency
        items.each_slice(@chunk_size) do |chunk|
          begin
            # Prepare records for ActiveRecord bulk insert
            records = chunk.map do |item|
              {
                test_case_id: item[:test_case_id],
                request_details: item[:request_details],
                file_paths: item[:file_paths],
                created_at: Time.current,
                updated_at: Time.current
              }
            end
            # Use ActiveRecord's bulk insert - handles connection pooling automatically
            TestCoverage.bulk_insert(records)
            
            Rails.logger.info("Coverband MySQL: Successfully inserted chunk of #{chunk.size} items via ActiveRecord") if Coverband.configuration.verbose
          rescue => e
            Rails.logger.error("Coverband MySQL: ActiveRecord chunk insert failed: #{e.message}")
            # Try individual inserts as fallback
            fallback_individual_inserts_activerecord(chunk)
          end
        end
      end
      
      def fallback_individual_inserts_activerecord(chunk)
        Rails.logger.info("Coverband MySQL: Falling back to individual ActiveRecord inserts for #{chunk.size} items")
        
        chunk.each do |item|
          begin
            TestCoverage.create!(
              test_case_id: item[:test_case_id],
              request_details: item[:request_details],
              file_paths: item[:file_paths]
            )
          rescue => e
            Rails.logger.error("Coverband MySQL: Individual ActiveRecord insert failed for test_case_id #{item[:test_case_id]}: #{e.message}")
          end
        end
      end
    end
  end
end