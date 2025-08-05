# frozen_string_literal: true

require_relative '../../models/coverband/test_case'
require_relative '../../models/coverband/request'
require_relative '../../models/coverband/coverage_method'
require_relative '../../models/coverband/test_coverage'
require 'json'

module Coverband
  class CoverageProcessor
    def initialize(shard_names: ['shard_2'])
      @shard_names = shard_names
    end

    def process_coverage_data(test_case_id, request_details, coverage_data)
      return false if test_case_id.nil? || coverage_data.nil? || coverage_data.empty?
      request_id = request_details[:jid] || request_details[:request_id] || "req_#{SecureRandom.hex(8)}"
      shard_name = @shard_names.sample
      Sharding.run_on_shard(shard_name) do
          Coverband::TestCase.insert_all([{
            test_case_id: test_case_id
        }])

        Coverband::Request.insert_all([{
            request_id: request_id,
            test_case_id: test_case_id,
            request_details: request_details
        }])
        insert_unique_method_names(coverage_data)
        method_map = Sharding.run_on_replica do
          build_method_id_map(request_id, coverage_data)
        end
        return false if method_map.empty?
        Coverband::TestCoverage.insert_all(method_map)        
      end
    rescue => e
      Rails.logger.info("Coverband: Final error in process_coverage_data: #{e.message}")
      NewRelic::Agent.notice_error(e)
      false # Always return false on error, never re-raise to avoid disrupting calling code
    end

    def process_coverage_data_from_worker(coverage_data)
      # Handle data format from Sidekiq worker
      test_case_data = coverage_data['test_case_data']
      method_calls = coverage_data['method_calls']
      
      return false unless test_case_data && method_calls
      
      # Convert method_calls to the expected format
      coverage_data_formatted = method_calls.map do |call|
        {
          full_method_name: call['full_method_name'],
          class_name: call['class_name'],
          method_name: call['method_name'],
          file_path: call['file_path']
        }
      end
      
      # Process using existing logic
      process_coverage_data(
        test_case_data['test_id'],
        test_case_data,
        coverage_data_formatted
      )
    end


    def build_method_id_map(request_id, coverage_data)
      method_names = coverage_data.map { |item| item[:full_method_name] }.uniq
      method_ids = Coverband::CoverageMethod.where(full_method_name: method_names).pluck(:id)
      method_ids.map { |id| { method_id: id, request_id: request_id } }
    end

    def insert_unique_method_names(coverage_data)
      unique_method_data = Sharding.run_on_replica do
        full_method_names = coverage_data.map { |item| item[:full_method_name] }
        full_method_names_in_db = Coverband::CoverageMethod.where(full_method_name: full_method_names).pluck(:full_method_name)
        full_method_names_to_insert = (full_method_names - full_method_names_in_db).to_set
        coverage_data.select { |item| full_method_names_to_insert.include?(item[:full_method_name]) }
      end
      return if unique_method_data.empty?
      Coverband::CoverageMethod.insert_all(unique_method_data)
    end

  end
end 