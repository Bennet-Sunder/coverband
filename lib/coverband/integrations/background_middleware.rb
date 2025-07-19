# frozen_string_literal: true

module Coverband
  class BackgroundMiddleware
    # Field mapping between readable names and single-letter keys for storage
    FIELD_MAPPING = {
      test_id: 'a',
      action_type: 'b',
      action_url: 'c',
      response_code: 'd'
    }.freeze
    
    REVERSE_MAPPING = FIELD_MAPPING.invert.freeze
    
    def initialize(app)
      @app = app
    end

    def call(env)
      test_case_data = nil
      original_test_case_id = if should_trace?(env)
        env['HTTP_X_TEST_CASE_ID']
      end
      if original_test_case_id&.present?
        Rails.logger.info("Coverband: Started tracing for #{original_test_case_id}")
        coverage_instance = Coverband::Collectors::DatadogCoverage.initialize_multi_threaded_coverage
        coverage_instance.start
        test_case_data = {
          test_id: original_test_case_id,
          action_type: env['REQUEST_METHOD'],
          action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
          response_code: nil,
          request_id: env['action_dispatch.request_id']
        }
        Thread.current[:coverband_test_case_id] = test_case_data
        Rails.logger.info("Coverband: Initial test case data: #{Thread.current[:coverband_test_case_id]}")
      else
        Thread.current[:coverband_test_case_id] = nil
      end

      status, headers, response = @app.call(env)
      if test_case_data
        test_case_data[:response_code] = status
        Rails.logger.info("Coverband: Updated test case data with status code: #{test_case_data}")
      end
      [status, headers, response]
    ensure
      if test_case_data
        begin
          coverage_results = coverage_instance.stop
          Coverband::Collectors::Coverage.save_multithreaded_coverage(test_case_data, coverage_results)
        rescue => e
          NewRelic::Agent.notice_error(e, { error: "Coverband storage failed for #{test_case_data.to_json}" })
        end        
      end
      Thread.current[:coverband_test_case_id] = nil
    end
    
    private

    def should_trace?(env)
      env['HTTP_X_TEST_CASE_ID'].present? && BaseRedis.key_exists?(Redis::RedisKeys::COVERBAND_ALL_REQUESTS)
    end

    def compress_keys(data)
      data.transform_keys { |k| FIELD_MAPPING[k] || k }
    end
    
    def expand_keys(data)
      data.transform_keys { |k| REVERSE_MAPPING[k] || k }
    end
  end
end
