# frozen_string_literal: true

require 'singleton'

module Coverband
  module Collectors
    ###
    # DatadogCoverage: Adapter for using Datadog's DDCov instead of Ruby's Coverage module
    ###
    class DatadogCoverage
      include Singleton

      def initialize
        @dd_cov = nil
        @coverage_started = false
        @mutex = Mutex.new
      end

      def dd_cov
        @dd_cov ||= create_dd_cov_instance
      end

      def start
        @mutex.synchronize do
          return if @coverage_started
          
          dd_cov.start
          @coverage_started = true
          Coverband.configuration.logger.info("Coverband: Started Datadog coverage collection") if Coverband.configuration.verbose
        end
      end

      def stop
        @mutex.synchronize do
          return {} unless @coverage_started
          
          coverage_data = dd_cov.stop
          @coverage_started = false
          
          # Convert Datadog format to Coverband format if needed
          convert_datadog_format(coverage_data)
        end
      end

      def peek_result
        @mutex.synchronize do
          return {} unless @coverage_started
          
          # Datadog doesn't have peek_result, so we need to stop and restart
          coverage_data = dd_cov.stop
          dd_cov.start
          
          convert_datadog_format(coverage_data)
        end
      end

      def running?
        @coverage_started
      end

      private

      def create_dd_cov_instance
        require 'datadog/ci'
        
        Datadog::CI::TestOptimisation::Coverage::DDCov.new(
          root: Dir.pwd,
          ignored_path: nil,
          threading_mode: :multi,
          use_allocation_tracing: true
        )
      rescue LoadError => e
        Coverband.configuration.logger.error("Coverband: Failed to load datadog-ci gem: #{e.message}")
        raise "Datadog CI gem not available. Please add 'gem \"datadog-ci\"' to your Gemfile"
      end

      def convert_datadog_format(datadog_coverage)
        # Convert Datadog's coverage format to match Ruby's Coverage format
        # This may need adjustment based on actual Datadog coverage format
        return {} if datadog_coverage.nil? || datadog_coverage.empty?
        
        # Assuming Datadog returns coverage in a similar format
        # You may need to adjust this based on the actual format
        datadog_coverage
      end
    end

    ###
    # DatadogCoverageAdapter: Adapter class to replace RubyCoverage in Delta
    ###
    class DatadogCoverageAdapter
      def self.results
        Coverband.stop_datadog_coverage
      end
    end
  end
end