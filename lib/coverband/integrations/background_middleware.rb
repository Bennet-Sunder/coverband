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
      original_test_case_id = env['HTTP_X_TEST_CASE_ID']
      test_case_data = nil
      if original_test_case_id&.present?
        Coverband.start_datadog_coverage
        Rails.logger.info("Coverband: Coverage reporting enabled for test case ID: #{original_test_case_id}")
        
        test_case_data = {
          test_id: original_test_case_id,
          action_type: env['REQUEST_METHOD'],
          action_url: "#{env['HTTP_HOST']}#{env['PATH_INFO']}",
          response_code: nil
        }
        
        # storage_data = compress_keys(test_case_data)
        Thread.current[:coverband_test_case_id] = test_case_data
        Rails.logger.info("Coverband: Initial test case data: #{Thread.current[:coverband_test_case_id]}")
      else
        Thread.current[:coverband_test_case_id] = nil
      end

      status, headers, response = @app.call(env)
      
      if test_case_data
        test_case_data[:response_code] = status
        # storage_data = compress_keys(test_case_data)
        Rails.logger.info("Coverband: Updated test case data with status code: #{test_case_data}")
      end
      [status, headers, response]
    ensure
      if test_case_data
        ::Coverband.report_new_coverage(test_case_data)
      end
      Thread.current[:coverband_test_case_id] = nil
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
