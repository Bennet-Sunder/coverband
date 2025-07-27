# frozen_string_literal: true

require_relative '../adapters/base'
require_relative '../../../app/services/coverband/coverage_processor'

module Coverband
  module Storage
    class OptimizedNormalizedStore < Coverband::Adapters::Base
      PWD_DIR = Dir.pwd + '/'
      
      def initialize(mysql_config = {})
        super()
        @mysql_config = mysql_config
        @processor = Coverband::CoverageProcessor.new(shard_names: mysql_config[:shard_names])
      end

      def save_report(coverage_data, test_case_details = {})
        # Early returns for invalid data
        return false if coverage_data.nil? || coverage_data.empty?
        return false unless coverage_data.is_a?(Hash) && coverage_data.values.first.is_a?(Hash)
        
        # Normalize test case details
        test_case_details&.symbolize_keys!
        return false unless test_case_details[:test_id]

        # Process the coverage data
        begin
          method_coverage = extract_method_coverage(coverage_data)
          return false if method_coverage.empty?
          process_coverage(
            test_case_details[:test_id],
            test_case_details,
            method_coverage
          )
        rescue => e
          Rails.logger.info("Coverband: Error saving coverage: #{e.message}")
          Rails.logger.info(e.backtrace.join("\n"))
          false
        end
      end

      # Alias for compatibility with the Coverage collector's save_method_report
      def save_method_report(coverage_data, test_case_details = {})
        save_report(coverage_data, test_case_details)
      end

      private

      def normalize_test_case_details(details)
        case details
        when String, Integer
          { test_id: details.to_s }
        when Hash
          details.symbolize_keys
        else
          {}
        end
      end

      def process_coverage(test_case_id, request_details, coverage_data)
        @processor.process_coverage_data(
          test_case_id,
          request_details,
          coverage_data
        )
      rescue => e
        Rails.logger.error("Coverband: Error processing coverage data: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n")) if Coverband.configuration.verbose
        false
      end

      def extract_method_coverage(report)
        method_coverage = []
        
        report.each do |file_path, coverage_data|
          next unless coverage_data.is_a?(Hash) && coverage_data.key?(:methods)
          
          methods = coverage_data[:methods]
          next if methods.nil? || methods.empty?
          
          # Get methods that were executed (count > 0)
          executed_methods = methods.select { |_, count| count && count > 0 }
          next if executed_methods.empty?
          
          relative_path = file_path.to_s.gsub(PWD_DIR, '')
          
          # Convert method identifiers to method names
          executed_methods.keys.each do |method_ident|
            if method_ident.is_a?(Array) && method_ident.length >= 2
              method_coverage << construct_method_fullname(relative_path, method_ident)
            end
          end
        end
        
        method_coverage
      end

      def construct_method_fullname(file_path, method_ident_array)
        return nil unless method_ident_array.is_a?(Array) && method_ident_array.length >= 2
        
        # Method identifier format: [class, method_name, ...]
        class_name = method_ident_array[0]
        method_name = method_ident_array[1]
        simplified_class_name = simplify_class_name(class_name.to_s)
        return nil if class_name.nil? || method_name.nil?
        
        # Simplify the class name and build the full method name
        {
          file_path: file_path,
          class_name: simplified_class_name,
          method_name: method_name,
          full_method_name: "#{simplified_class_name}##{method_name}"
        }
      rescue => e
        Rails.logger.error("Coverband: Error constructing method name: #{e.message}")
        nil
      end

      def simplify_class_name(class_name)
        # Remove any verbose class name formatting
        # Example: "#<Class:Cmdb::CiLevel_0Field(id: integer, ...)>" -> "Cmdb::CiLevel_0Field"
        class_name.gsub(/\#\<Class\:(.*?)\(.*?\)>/, '\1')
                 .gsub(/\#\<Class\:(.*?)\>/, '\1')
      end
    end
  end
end 