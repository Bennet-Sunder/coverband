# frozen_string_literal: true
require 'benchmark'
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
      original_test_case_id = env['HTTP_X_TEST_CASE_ID']
      timing_data = {}
      
      test_case_data = nil
      if original_test_case_id&.present?
        # Measure tracing time
        tracing_time = Benchmark.realtime do
          ::Coverage.result(clear: true, stop: false)
        end
        timing_data[:tracing_time] = tracing_time

        Rails.logger.info("Coverband: Coverage reporting enabled for test case ID: #{original_test_case_id}")
        test_case_data = {
          test_id: original_test_case_id,
          action_type: env['REQUEST_METHOD'],
          action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
          response_code: nil
        }
        Thread.current[:coverband_test_case_id] = test_case_data
        Rails.logger.info("Coverband: Initial test case data: #{Thread.current[:coverband_test_case_id]}")
      else
        Thread.current[:coverband_test_case_id] = nil
      end
      status, headers, response = nil, nil, nil
      app_call_time = Benchmark.realtime do
        status, headers, response = @app.call(env)
        if test_case_data
          test_case_data[:response_code] = status
          Rails.logger.info("Coverband: Updated test case data with status code: #{test_case_data}")
        end
      end

      timing_data[:app_call_time] = app_call_time
      [status, headers, response]
    ensure
      Thread.current[:coverband_test_case_id] = nil
      if test_case_data
        reporting_time = Benchmark.realtime do
          ::Coverband.report_new_coverage(test_case_data)
        end
        timing_data[:reporting_time] = reporting_time
        Rails.logger.info("Coverband: Timing data for test case ID #{test_case_data[:action_type]}: #{timing_data}")
        NewRelic::Agent.notice_error(StandardError.new("Coverband Timing Data"), test_case_data: test_case_data, timing_data: timing_data)
      end
    end
    
    private
    
    def compress_keys(data)
      data.transform_keys { |k| FIELD_MAPPING[k] || k }
    end
    
    def expand_keys(data)
      data.transform_keys { |k| REVERSE_MAPPING[k] || k }
    end
  end
end
