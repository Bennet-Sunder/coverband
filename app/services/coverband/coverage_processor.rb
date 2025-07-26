# frozen_string_literal: true

require_relative '../../models/coverband/test_case'
require_relative '../../models/coverband/request'
require_relative '../../models/coverband/coverage_method'
require_relative '../../models/coverband/test_coverage'
require 'json'

module Coverband
  class CoverageProcessor
    def initialize(max_retries: 3, base_delay: 0.1)
      @max_retries = max_retries
      @base_delay = base_delay
    end

    def process_coverage_data(test_case_id, request_details, coverage_data)
      return false if test_case_id.nil? || coverage_data.nil? || coverage_data.empty?
      request_id = request_details[:jid] || request_details[:request_id] || "req_#{SecureRandom.hex(8)}"

      Coverband::TestCase.insert_all([{
          test_case_id: test_case_id
      }])

      Coverband::Request.insert_all([{
          request_id: request_id,
          test_case_id: test_case_id,
          request_details: request_details
      }])

      Coverband::CoverageMethod.insert_all(coverage_data)
      method_map = build_method_id_map(request_id, coverage_data)
      return false if method_map.empty?
      Coverband::TestCoverage.insert_all(method_map)
    rescue => e
      Rails.logger.info("Coverband: Final error in process_coverage_data: #{e.message}")
      NewRelic::Agent.notice_error(e)
      false # Always return false on error, never re-raise to avoid disrupting calling code
    end


    def build_method_id_map(request_id, coverage_data)
      method_names = coverage_data.map { |item| item[:full_method_name] }.uniq
      method_ids = Coverband::CoverageMethod.where(full_method_name: method_names).pluck(:id)
      method_ids.map { |id| { method_id: id, request_id: request_id } }
    end
  end
end 