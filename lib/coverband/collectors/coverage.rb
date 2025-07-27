# frozen_string_literal: true

require "singleton"
require_relative "delta"

module Coverband
  module Collectors
    ###
    # StandardError seems like be better option
    # coverband previously had RuntimeError here
    # but runtime error can let a large number of error crash this method
    # and this method is currently in a ensure block in middleware and threads
    ###
    class Coverage
      include Singleton

      def reset_instance
        @project_directory = File.expand_path(Coverband.configuration.root)
        @ignore_patterns = Coverband.configuration.ignore
        @store = Coverband.configuration.store
        @verbose = Coverband.configuration.verbose
        @logger = Coverband.configuration.logger
        @test_env = Coverband.configuration.test_env
        Delta.reset
        self
      end

      def runtime!
        @store.type = Coverband::RUNTIME_TYPE
      end

      def eager_loading!
        @store.type = Coverband::EAGER_TYPE
      end

      def eager_loading
        old_coverage_type = @store.type
        eager_loading!
        yield
      ensure
        report_coverage
        @store.type = old_coverage_type
      end

      def toggle_eager_loading
        old_coverage_type = @store.type
        eager_loading!
        yield
      ensure
        @store.type = old_coverage_type
      end

      def report_new_coverage(test_case_details = {})
        Rails.logger.info("Coverband: report_coverage test case ID: #{test_case_details.inspect}")
        @semaphore.synchronize do
          raise "no Coverband store set" unless @store
          @store.save_report(Delta.results, test_case_details)
        end
      rescue => e
        Rails.logger.info("Coverband: Coverage storage failed for test case ID: #{test_case_details.inspect}")
        @logger&.error "coverage failed to store"
        @logger&.error "Coverband Error: #{e.inspect} #{e.message}"
        e.backtrace.each { |line| @logger&.error line } if @verbose
        raise e if @test_env      
      end

      def self.save_multithreaded_coverage(test_case_details = {})
        coverage_results = ::Coverage.result(clear: true, stop: false)
        if coverage_results.nil? || coverage_results.empty?
          Rails.logger.info("Coverband: No coverage results for test case #{test_case_details.inspect}")
        end
        Coverband.configuration.store.save_method_report(coverage_results, test_case_details)
      rescue => e
        Rails.logger.info("Coverband: Coverage storage failed for test case ID: #{test_case_details.inspect}")
      end      

      def self.save_sidekiq_coverage(test_case_details)
        begin
          # NOTE: This uses Ruby's Coverage module which is process-global, not thread-local.
          # In a multi-threaded Sidekiq environment, this coverage data may include methods
          # called by concurrent jobs running in other threads.
          #
          # This is a fundamental limitation of Ruby's Coverage module and cannot be easily
          # worked around without significant performance overhead or architectural changes.
          coverage_results = ::Coverage.result(clear: true, stop: false)
          Coverband.configuration.store.save_method_report(coverage_results, test_case_details)
        rescue => e
          Rails.logger.info "FAILED: Storing sidekiq coverage for test case: #{test_case_details.inspect} with error: #{e.message} and #{e.backtrace.join("\n")}"
        end
      end

      def report_coverage(test_case_id = nil)
        return
        Rails.logger.info("Coverband: report_coverage test case ID: #{test_case_id}")
        @semaphore.synchronize do
          raise "no Coverband store set" unless @store
          files_with_line_usage = filtered_files(Delta.results)
          if @store.type == Coverband::EAGER_TYPE && Coverband.configuration.defer_eager_loading_data?
            @deferred_eager_loading_data = files_with_line_usage
          else
            if @deferred_eager_loading_data && Coverband.configuration.defer_eager_loading_data?
              toggle_eager_loading do
                @store.save_report(@deferred_eager_loading_data) if Coverband.configuration.send_deferred_eager_loading_data?
                @deferred_eager_loading_data = nil
              end
            end
            Rails.logger.info("Coverband: save_report test case ID: #{test_case_id}")
            @store.save_report(files_with_line_usage, test_case_id)
          end
        end
      rescue => e
        Rails.logger.info("Coverband: Coverage storage failed for test case ID: #{test_case_id}")
        @logger&.error "coverage failed to store"
        @logger&.error "Coverband Error: #{e.inspect} #{e.message}"
        e.backtrace.each { |line| @logger&.error line } if @verbose
        raise e if @test_env
      end

      private

      def filtered_files(new_results)
        new_results.select! do |_file, coverage_data_for_file|
          if coverage_data_for_file.is_a?(Hash) && coverage_data_for_file.key?(:methods)
            # Methods coverage format: { methods: {...} }
            methods_present = false
            if coverage_data_for_file[:methods].is_a?(Hash)
              methods_present = coverage_data_for_file[:methods]&.any? { |_method_ident_array, count| count&.nonzero? }
            end
            methods_present
          else
            false # Unknown format or no methods coverage, filter out
          end
        end
        new_results # select! modifies in place, but returning is fine for clarity
      end

      def initialize
        @semaphore = Mutex.new
        require "coverage"
        if RUBY_PLATFORM == "java"
          unless ::Coverage.respond_to?(:line_stub)
            require "coverband/utils/jruby_ext"
          end
        end
        if defined?(SimpleCov) && defined?(Rails) && defined?(Rails.env) && Rails.env.test?
          Rails.logger.info "Coverband: detected SimpleCov in test Env, allowing it to start Coverage"
          Rails.logger.info "Coverband: to ensure no error logs or missing Coverage call `SimpleCov.start` prior to requiring Coverband"
        elsif ::Coverage.respond_to?(:state)
          if ::Coverage.state == :idle
            ::Coverage.start(methods: true) unless ENV["DISABLE_AUTO_START"]
          elsif ::Coverage.state == :suspended
            ::Coverage.resume
          end
        else
          ::Coverage.start(methods: true) unless ENV["DISABLE_AUTO_START"]
        end
        reset_instance
      end
    end
  end
end
