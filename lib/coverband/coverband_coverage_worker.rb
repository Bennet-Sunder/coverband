# frozen_string_literal: true

module Coverband
  class CoverbandCoverageWorker < BaseWorker
    sidekiq_options queue: :lightweight_low, retry: 3

    def perform(args)
      coverage_data_key = args[:coverage_data_key]
      request_id = args[:request_id]
      coverage_data = BaseRedis.get_key(coverage_data_key)
      return unless coverage_data
      
      begin
        parsed_data = JSON.parse(coverage_data)
        test_case_data = parsed_data['test_case_data']
        method_calls = parsed_data['method_calls']
        Coverband::Collectors::TracepointMethodTracker.save_tracepoint_coverage(test_case_data, method_calls)
        #BaseRedis.remove_key(coverage_data_key)
      rescue => e
        Rails.logger.info "Coverband: CoverbandCoverageWorker failed: #{e.message}"
        NewRelic::Agent.notice_error(e, { error: "Coverband storage failed for #{test_case_data.to_json}" })
      end
    end
  end
end 