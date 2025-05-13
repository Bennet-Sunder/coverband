# frozen_string_literal: true

module Coverband
  class BackgroundMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      test_case_id = env['HTTP_X_TEST_CASE_ID']
      @app.call(env)
    ensure
      ::Coverband.report_coverage(test_case_id)
      # AtExit.register
      # Background.start if Coverband.configuration.background_reporting_enabled
    end
  end
end
