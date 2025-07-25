# frozen_string_literal: true

module Coverband
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
        puts("Coverband: Started tracing for #{original_test_case_id}")
        # Use Ruby's Coverage module - simple and reliable
        ::Coverage.result(clear: true, stop: false)
        test_case_data = {
          test_id: original_test_case_id,
          action_type: env['REQUEST_METHOD'],
          action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
          response_code: nil,
          request_id: env['action_dispatch.request_id']
        }
        Thread.current[:coverband_test_case_id] = test_case_data
        puts("Coverband: Initial test case data: #{Thread.current[:coverband_test_case_id]}")
      else
        Thread.current[:coverband_test_case_id] = nil
      end

      status, headers, response = @app.call(env)
      if test_case_data
        test_case_data[:response_code] = status
        puts("Coverband: Updated test case data with status code: #{test_case_data}")
      end
      [status, headers, response]
    ensure
      if test_case_data
        begin
          # Use simple Ruby Coverage approach for HTTP requests
          # Note: In Passenger, each request runs in separate process so isolation is natural
          Coverband::Collectors::Coverage.save_multithreaded_coverage(test_case_data)
        rescue => e
          if defined?(NewRelic::Agent)
            NewRelic::Agent.notice_error(e, { error: "Coverband storage failed for #{test_case_data.to_json}" })
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
  end
end
