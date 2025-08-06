# frozen_string_literal: true

module Coverband
  # Temporary coverage data expiry for background job processing
  TEMPORARY_COVERAGE_EXPIRY = 60.minutes.to_i

  class BackgroundMiddleware
    # Field mapping between readable names and single-letter keys for storage
    FIELD_MAPPING = {
      'test_case_id' => 't',
      'action_url' => 'u',
      'action_type' => 'a',
      'response_code' => 'r'
    }.freeze

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
        
        test_case_data = {
          test_id: original_test_case_id,
          action_type: env['REQUEST_METHOD'],
          action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
          response_code: nil,
          request_id: env['action_dispatch.request_id']
        }
        
        if Coverband.configuration.use_tracepoint_for_app_requests
          # Use TracePoint approach
          Thread.current[:coverband_test_case_id] = test_case_data
          Thread.current[:method_calls] = []
          Rails.logger.info("Coverband: Using TracePoint for app request")
        else
          # Use Coverage module approach
          ::Coverage.result(clear: true, stop: false)
          Thread.current[:coverband_test_case_id] = test_case_data
          Rails.logger.info("Coverband: Using Coverage module for app request")
        end
        
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
          if Coverband.configuration.use_tracepoint_for_app_requests
            # Save method coverage using TracePoint data
            method_calls = Thread.current[:method_calls] || []
            queue_coverage_job(test_case_data, method_calls)
            
            # Clean up thread-local data
            Thread.current[:coverband_test_case_id] = nil
            Thread.current[:method_calls] = nil
          else
            # Use Coverage module approach
            queue_coverage_job(test_case_data)
          end
        rescue => e
          if defined?(NewRelic::Agent)
            NewRelic::Agent.notice_error(e, { error: "Coverband job queuing failed for #{test_case_data.to_json}" })
          end
        end        
      end
      Thread.current[:coverband_test_case_id] = nil
    end
    
    private

    def should_trace?(env)
      env['HTTP_X_TEST_CASE_ID'].present?
      # Note: Original implementation also checked BaseRedis.key_exists?(Redis::RedisKeys::COVERBAND_ALL_REQUESTS)
      # but that key might not be available in this branch
    end

    def compress_keys(data)
      data.transform_keys { |k| FIELD_MAPPING[k] || k }
    end

    def queue_coverage_job(test_case_data, method_calls = nil)
      coverage_data_key = "coverband_coverage:#{test_case_data[:request_id]}"
      
      coverage_data = {
        test_case_data: test_case_data,
        method_calls: method_calls
      }
      
      BaseRedis.set_key_and_expiry(coverage_data_key, coverage_data.to_json, TEMPORARY_COVERAGE_EXPIRY)
      GlobalSidekiqWorker.enqueue(Coverband::CoverbandCoverageWorker, { coverage_data_key: coverage_data_key, request_id: test_case_data[:request_id] })
      
      Rails.logger.info("Coverband: Queued coverage job for request #{test_case_data[:request_id]}")
    end
  end
end
