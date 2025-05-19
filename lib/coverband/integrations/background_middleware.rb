# frozen_string_literal: true

module Coverband
  class BackgroundMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      test_case_id = env['HTTP_X_TEST_CASE_ID']
      if test_case_id
        Thread.current[:coverband_test_case_id] = test_case_id
      end
      @app.call(env)
    ensure
      # The original test_case_id from the request is used for the request's coverage report
      ::Coverband.report_coverage(test_case_id) if test_case_id
      # Clear the test_case_id from Thread.current to avoid leakage
      Thread.current[:coverband_test_case_id] = nil
      # AtExit.register
      # Background.start if Coverband.configuration.background_reporting_enabled
    end
  end
end
