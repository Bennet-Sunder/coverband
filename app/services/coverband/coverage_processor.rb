# frozen_string_literal: true

require_relative '../../models/coverband/test_case'
require_relative '../../models/coverband/request'
require_relative '../../models/coverband/coverage_file'
require_relative '../../models/coverband/coverage_method'
require_relative '../../models/coverband/test_coverage'
require 'json'

module Coverband
  class CoverageProcessor
    def initialize(batch_size: 1000)
      @batch_size = batch_size
    end

    def process_coverage_data(test_case_id, request_details, coverage_data)
      return false if test_case_id.nil? || coverage_data.nil? || coverage_data.empty?

      # Ensure request_details is valid JSON
      begin
        request_details_json = if request_details.is_a?(String)
          # If it's already a string, validate it's proper JSON
          JSON.parse(request_details)
          request_details
        else
          # If it's a hash or other object, convert to JSON string
          request_details.to_json
        end
      rescue JSON::ParserError => e
        puts("Coverband: Invalid JSON in request_details: #{e.message}")
        puts("Coverband: request_details: #{request_details.inspect}")
        return false
      end

      ActiveRecord::Base.transaction do
        begin
          puts("Coverband: Starting coverage processing for test_case_id: #{test_case_id}")

          # Step 1: Insert test case and get its ID
          insert_test_case_sql = <<-SQL
            INSERT IGNORE INTO #{Coverband::TestCase.table_name} 
            (test_case_id, created_at)
            VALUES (#{connection.quote(test_case_id)}, CURRENT_TIMESTAMP);
          SQL
          connection.execute(insert_test_case_sql)
          
          select_test_case_sql = <<-SQL
            SELECT id FROM #{Coverband::TestCase.table_name}
            WHERE test_case_id = #{connection.quote(test_case_id)};
          SQL
          test_case_db_id = connection.select_value(select_test_case_sql)
          
          if test_case_db_id.nil?
            puts("Coverband: Failed to get test case ID for test_case_id: #{test_case_id}")
            return false
          end
          puts("Coverband: Created/Found test case with ID: #{test_case_db_id}")

          # Step 2: Insert request and get its ID
          insert_request_sql = <<-SQL
            INSERT IGNORE INTO #{Coverband::Request.table_name} 
            (test_case_id, request_details, created_at)
            VALUES (#{test_case_db_id}, CAST(#{connection.quote(request_details_json)} AS JSON), CURRENT_TIMESTAMP);
          SQL
          connection.execute(insert_request_sql)
          
          select_request_sql = <<-SQL
            SELECT id FROM #{Coverband::Request.table_name}
            WHERE test_case_id = #{test_case_db_id}
            AND JSON_CONTAINS(request_details, #{connection.quote(request_details_json)})
            AND JSON_CONTAINS(#{connection.quote(request_details_json)}, request_details);
          SQL
          request_id = connection.select_value(select_request_sql)
          
          if request_id.nil?
            puts("Coverband: Failed to get request ID for test_case_id: #{test_case_id}, test_case_db_id: #{test_case_db_id}")
            puts("Coverband: request_details_json: #{request_details_json}")
            return false
          end
          puts("Coverband: Created/Found request with ID: #{request_id}")

          # Step 3: Insert all files at once
          file_paths = coverage_data.keys
          if file_paths.empty?
            puts("Coverband: No file paths found in coverage data")
            return false
          end

          file_values = file_paths.map { |path| 
            "(#{connection.quote(path)}, CURRENT_TIMESTAMP)"
          }.join(",")
          insert_files_sql = <<-SQL
            INSERT IGNORE INTO #{Coverband::CoverageFile.table_name} 
            (file_path, created_at)
            VALUES #{file_values};
          SQL
          connection.execute(insert_files_sql)
          
          select_files_sql = <<-SQL
            SELECT file_path, id FROM #{Coverband::CoverageFile.table_name}
            WHERE file_path IN (#{file_paths.map { |p| connection.quote(p) }.join(',')});
          SQL
          file_ids = connection.select_rows(select_files_sql).to_h
          
          if file_ids.empty?
            puts("Coverband: Failed to get file IDs for paths: #{file_paths.join(', ')}")
            return false
          end
          puts("Coverband: Created/Found #{file_ids.size} files")

          # Step 4: Insert all methods at once
          method_records = []
          coverage_data.each do |file_path, methods|
            file_id = file_ids[file_path]
            unless file_id
              puts("Coverband: Missing file_id for path: #{file_path}")
              next
            end

            methods.each do |method_name|
              if method_name.include?('#')
                class_name, method = method_name.split('#', 2)
                method_records << {
                  file_id: file_id,
                  class_name: class_name,
                  method_name: method,
                  full_method_name: method_name
                }
              else
                method_records << {
                  file_id: file_id,
                  method_name: method_name,
                  full_method_name: method_name
                }
              end
            end
          end

          if method_records.empty?
            puts("Coverband: No method records generated from coverage data")
            return false
          end

          method_values = method_records.map { |m|
            "(#{m[:file_id]}, #{connection.quote(m[:class_name])}, #{connection.quote(m[:method_name])}, #{connection.quote(m[:full_method_name])}, CURRENT_TIMESTAMP)"
          }.join(",")

          insert_methods_sql = <<-SQL
            INSERT IGNORE INTO #{Coverband::CoverageMethod.table_name}
            (file_id, class_name, method_name, full_method_name, created_at)
            VALUES #{method_values};
          SQL
          connection.execute(insert_methods_sql)
          
          select_methods_sql = <<-SQL
            SELECT full_method_name, id FROM #{Coverband::CoverageMethod.table_name}
            WHERE file_id IN (#{file_ids.values.join(',')})
            AND full_method_name IN (#{method_records.map { |m| connection.quote(m[:full_method_name]) }.join(',')});
          SQL
          method_ids = connection.select_rows(select_methods_sql).to_h
          
          if method_ids.empty?
            puts("Coverband: Failed to get method IDs for records: #{method_records.map { |m| m[:full_method_name] }.join(', ')}")
            return false
          end
          puts("Coverband: Created/Found #{method_ids.size} methods")

          # Step 5: Insert all test coverages in batches
          total_coverages = 0
          method_ids.values.each_slice(@batch_size) do |batch|
            coverage_values = batch.map { |method_id|
              "(#{request_id}, #{method_id}, CURRENT_TIMESTAMP)"
            }.join(",")

            insert_coverages_sql = <<-SQL
              INSERT IGNORE INTO #{Coverband::TestCoverage.table_name}
              (request_id, method_id, created_at)
              VALUES #{coverage_values};
            SQL
            connection.execute(insert_coverages_sql)
            total_coverages += batch.size
          end
          puts("Coverband: Created #{total_coverages} test coverage records")

          puts("Coverband: Successfully completed coverage processing for test_case_id: #{test_case_id}")
          true
        rescue => e
          puts("Coverband: Error processing coverage data: #{e.message}")
          puts("Coverband: Error backtrace: #{e.backtrace.join("\n")}") if Coverband.configuration.verbose
          puts("Coverband: Coverage data that caused error: #{coverage_data.inspect}")
          raise # Re-raise to trigger rollback
        end
      end
    rescue => e
      puts("Coverband: Outer error in process_coverage_data: #{e.message}")
      puts("Coverband: Outer error backtrace: #{e.backtrace.join("\n")}") if Coverband.configuration.verbose
      false
    end

    private

    def connection
      ActiveRecord::Base.connection
    end
  end
end 