# frozen_string_literal: true

module Coverband
  module Integrations
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        Rails.logger.info "Coverband: Adding test case ID to Sidekiq job #{Thread.current[:coverband_test_case_id]}"
        if Thread.current[:coverband_test_case_id]
          job['coverband_test_case_id'] = Thread.current[:coverband_test_case_id]
        end
        yield
      end
    end

    class SidekiqServerMiddleware
      def call(_worker, job, _queue)
        test_case_data = job['coverband_test_case_id']
        test_case_data['response_code'] = _worker.class
        Rails.logger.info "Coverband: Starting coverage for test case ID #{test_case_data}"
        yield
      ensure
        ::Coverband.report_new_coverage(test_case_data)
      end
    end
  end
end

if defined?(::Sidekiq)
  # The :startup hook for Sidekiq server processes should remain here,
  # as it's a direct Sidekiq lifecycle configuration.
  ::Sidekiq.configure_server do |config|
    config.on(:startup) do
      ::Coverband.start
      ::Coverband.runtime_coverage!
    end
  end
  # Middleware chain configuration will be handled by the Railtie for Rails apps.
  # For non-Rails apps using Sidekiq, users might need to add middleware manually
  # or Coverband could provide a setup method to be called explicitly.
end
