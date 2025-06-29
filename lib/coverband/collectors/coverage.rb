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
          @store.save_method_report(filtered_files(Delta.results), test_case_details)
        end
      rescue => e
        Rails.logger.info("Coverband: Coverage storage failed for test case ID: #{test_case_details.inspect}")
        @logger&.error "coverage failed to store"
        @logger&.error "Coverband Error: #{e.inspect} #{e.message}"
        e.backtrace.each { |line| @logger&.error line } if @verbose
        raise e if @test_env      
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
          if coverage_data_for_file.is_a?(Hash) && coverage_data_for_file.key?(:lines)
            # New format: { lines: [...], methods: {...} }
            lines_present = coverage_data_for_file[:lines]&.any? { |value| value&.nonzero? }
            methods_present = false
            if coverage_data_for_file.key?(:methods) && coverage_data_for_file[:methods].is_a?(Hash)
              methods_present = coverage_data_for_file[:methods]&.any? { |_method_ident_array, count| count&.nonzero? }
            end
            lines_present || methods_present
          elsif coverage_data_for_file.is_a?(Array)
            # Old format or lines-only: [...]
            coverage_data_for_file.any? { |value| value&.nonzero? }
          else
            false # Unknown format, filter out
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
          puts "Coverband: detected SimpleCov in test Env, allowing it to start Coverage"
          puts "Coverband: to ensure no error logs or missing Coverage call `SimpleCov.start` prior to requiring Coverband"
        elsif ::Coverage.respond_to?(:state)
          if ::Coverage.state == :idle
            ::Coverage.start(lines: true, methods: true)
          elsif ::Coverage.state == :suspended
            ::Coverage.resume
          end
        else
          ::Coverage.start(lines: true, methods: true) unless ::Coverage.running?
        end
        reset_instance
      end
    end
  end
end
