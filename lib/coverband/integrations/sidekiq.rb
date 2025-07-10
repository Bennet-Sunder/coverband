# frozen_string_literal: true

module Coverband
  module Integrations
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        Rails.logger.info("Coverband: Sidekiq Client Middleware called for job: #{Thread.current[:coverband_test_case_id].inspect}")
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
          Coverband::Collectors::DatadogCoverage.start_single_threaded_coverage
        end
        yield
      ensure
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
