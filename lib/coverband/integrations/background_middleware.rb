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
      Rails.logger.info("Coverage Running?: #{::Coverage.running?}")
      original_test_case_id = env['HTTP_X_TEST_CASE_ID']
      timing_data = {
        tracing_time: 0,
        app_call_time: 0,
        reporting_time: 0
      }
      
      test_case_data = nil
      test_case_data = {
        test_id: original_test_case_id,
        action_type: env['REQUEST_METHOD'],
        action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
        response_code: nil
      }

      if original_test_case_id&.present?
        # Measure tracing time
        unless ENV['DISABLE_AUTO_START']
          tracing_time = Benchmark.realtime do
            ::Coverage.result(clear: true, stop: false) 
          end
          timing_data[:tracing_time] = tracing_time
        end
        Rails.logger.info("Coverband: Coverage reporting enabled for test case ID: #{original_test_case_id}")
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
      final_processing_time = 0
      if test_case_data && !ENV['DISABLE_AUTO_START']
        reporting_time = Benchmark.realtime do
          final_processing_time = ::Coverband.report_new_coverage(test_case_data)
        end
        timing_data[:reporting_time] = reporting_time
        timing_data[:final_processing_time] = final_processing_time
      end
      Rails.logger.info("Coverband: Timing data for test case ID #{test_case_data[:action_type]}: #{timing_data}")
      FsLogger.journey_service_requests("#{::Coverage.running?},#{test_case_data[:action_type]},#{test_case_data[:action_url]}, #{timing_data[:tracing_time]},#{timing_data[:app_call_time]},#{timing_data[:reporting_time]},#{timing_data[:final_processing_time]}")
      NewRelic::Agent.notice_error(StandardError.new("Coverband Timing Data"), test_case_data: test_case_data, timing_data: timing_data)

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
