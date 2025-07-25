# frozen_string_literal: true

module Coverband
  module Integrations
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        Rails.logger.info "Coverband: Adding test case ID to Sidekiq job #{Thread.current[:coverband_test_case_id]}"
        if Thread.current[:coverband_test_case_id]
          job['coverband_test_case_id'] = {
            test_id: Thread.current[:coverband_test_case_id][:test_id],
            request_id: Thread.current[:message_uuid],
            worker_name: _worker_class,
            jid: job['jid']
          }
        end
        yield
      end
    end

    class SidekiqServerMiddleware
      def call(_worker, job, _queue)
        test_case_data = job['coverband_test_case_id']
        if test_case_data
          Thread.current[:coverband_test_case_id] = test_case_data
          ::Coverage.result(clear: true, stop: false)
        end
        yield
      ensure
        if test_case_data
          begin
            # Use Ruby's Coverage module to get method coverage
            # Note: This is process-wide coverage and may include methods from concurrent jobs
            # For accurate per-job tracking, we can revisit TracePoint approach later
            Coverband::Collectors::Coverage.save_sidekiq_coverage(test_case_data)
          rescue => e
            NewRelic::Agent.notice_error(e, { error: "Coverband storage failed for #{test_case_data.to_json}" })
            Rails.logger.info("Coverband: Error saving coverage: #{e.message}")
          end
        end
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
