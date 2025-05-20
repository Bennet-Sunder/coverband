# frozen_string_literal: true

module Coverband
  class BackgroundMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      original_test_case_id = env['HTTP_X_TEST_CASE_ID']
      # This variable will hold the (potentially augmented) ID used for coverage reporting
      reporting_id_for_coverage = nil

      if original_test_case_id
        # Construct a unique identifier for the request part using method and path
        # Example: "GET|/users/1"
        request_identifier = "#{env['REQUEST_METHOD']}|#{env['PATH_INFO']}"
        
        # Combine with the original test case ID using a clear separator "::REQ::"
        # Example: "your_test_case_id::REQ::GET|/users/1"
        reporting_id_for_coverage = "#{original_test_case_id}::REQ::#{request_identifier}"

        # Set the augmented ID in Thread.current so it can be picked up by Coverband.report_coverage
        # This is also useful if other parts of the system (like Sidekiq jobs spawned from this request)
        # rely on Thread.current[:coverband_test_case_id].
        Thread.current[:coverband_test_case_id] = reporting_id_for_coverage
      else
        # If no original_test_case_id, ensure Thread.current is nil for this thread.
        Thread.current[:coverband_test_case_id] = nil
      end

      @app.call(env)
    ensure
      # Report coverage only if an original_test_case_id was present for this request.
      # The ID used for reporting will be the augmented one (reporting_id_for_coverage).
      if original_test_case_id && reporting_id_for_coverage
        ::Coverband.report_coverage(reporting_id_for_coverage)
      end
      
      # Always clear the Thread.current variable after the request to prevent leakage 
      # to subsequent requests handled by this thread that are not part of this test case.
      Thread.current[:coverband_test_case_id] = nil
    end
  end
end
