# frozen_string_literal: true

module Coverband
  module Integrations
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        if (test_case_id = Thread.current[:coverband_test_case_id])
          job['coverband_test_case_id'] = test_case_id
        end
        yield
      end
    end

    class SidekiqServerMiddleware
      def call(_worker, job, _queue)
        test_case_id = job['coverband_test_case_id']
        yield
      ensure
        ::Coverband.report_coverage(test_case_id) if test_case_id
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
