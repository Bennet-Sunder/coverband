# frozen_string_literal: true

module Coverband
  module Integrations
    # Temporary coverage data expiry for background job processing
    TEMPORARY_COVERAGE_EXPIRY = 60.minutes.to_i

    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        Rails.logger.info "Coverband: Adding test case ID to Sidekiq job #{Thread.current[:coverband_test_case_id]}"

        if Thread.current[:coverband_test_case_id] && _worker_class != 'Coverband::CoverbandCoverageWorker'
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
        puts "Sideqkiq executing worker #{_worker.class.name}"
        puts "Sidekiq running on process #{Process.pid}"
        puts "Sidekiq running on thread #{Thread.current.object_id}"
        
        if test_case_data
          # Always use TracePoint for Sidekiq (multi-threaded environment)
          Thread.current[:coverband_test_case_id] = test_case_data
          Thread.current[:method_calls] = []
        end
        
        yield
        
      ensure
        if test_case_data
          begin
            # Queue coverage writing to background job instead of writing synchronously
            method_calls = Thread.current[:method_calls] || []
            queue_sidekiq_coverage_job(test_case_data, method_calls)
            
            # Clean up thread-local data
            Thread.current[:coverband_test_case_id] = nil
            Thread.current[:method_calls] = nil
            
          rescue => e
            NewRelic::Agent.notice_error(e, { error: "Coverband job queuing failed for #{test_case_data.to_json}" })
            Rails.logger.info("Coverband: Error queuing coverage job: #{e.message}")
          end
        end
      end

      private

      def queue_sidekiq_coverage_job(test_case_data, method_calls)
        coverage_data_key = "coverband_sidekiq_coverage:#{test_case_data[:jid]}"
        
        coverage_data = {
          test_case_data: test_case_data,
          method_calls: method_calls
        }
        
        BaseRedis.set_key_and_expiry(coverage_data_key, coverage_data.to_json, TEMPORARY_COVERAGE_EXPIRY)
        GlobalSidekiqWorker.enqueue(Coverband::CoverbandCoverageWorker, { coverage_data_key: coverage_data_key, request_id: test_case_data[:jid] })
        
        Rails.logger.info("Coverband: Queued Sidekiq coverage job for job #{test_case_data[:jid]}")
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
      
      # Always setup global TracePoint for Sidekiq (multi-threaded environment)
      Coverband::Collectors::TracepointMethodTracker.setup_global_tracepoint
    end
  end
  # Middleware chain configuration will be handled by the Railtie for Rails apps.
  # For non-Rails apps using Sidekiq, users might need to add middleware manually
  # or Coverband could provide a setup method to be called explicitly.
end
