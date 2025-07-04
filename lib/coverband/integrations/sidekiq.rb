# frozen_string_literal: true

module Coverband
  module Integrations
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        puts "Coverband: Adding test case ID to Sidekiq job #{Thread.current[:coverband_test_case_id]}"

        if Thread.current[:coverband_test_case_id]
          job['coverband_test_case_id'] = Thread.current[:coverband_test_case_id]
        end
        yield
      end
    end

    class SidekiqServerMiddleware
      def call(_worker, job, _queue)
        test_case_data = job['coverband_test_case_id']
        test_case_data['response_code'] = _worker.class if test_case_data.key?('response_code')
        Coverband::Collectors::DatadogCoverage.start_single_threaded_coverage
        puts ("#{::Thread.current.object_id} Coverband: Starting SidekiqServerMiddleware for job: #{job.inspect}")
        yield
      ensure
        puts ("#{::Thread.current.object_id} Coverband: Starting SidekiqServerMiddleware ENSURE for job: #{job.inspect}")
        if test_case_data
          begin
            Coverband::Collectors::Coverage.save_sidekiq_coverage(test_case_data)
          rescue => e
            NewRelic::Agent.notice_error(e, { error: "Coverband storage failed for #{test_case_data.to_json}" })
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
