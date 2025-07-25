# frozen_string_literal: true

module Coverband
  module Collectors
    class Delta
      @@previous_coverage = {}
      @@stubs = {}

      attr_reader :current_coverage

      def initialize(current_coverage)
        @current_coverage = current_coverage
      end

      class RubyCoverage
        def self.results
          ::Coverage.peek_result
        end
      end

      def self.results(process_coverage = RubyCoverage)
        coverage_results = process_coverage.results
        new(coverage_results).results
      end

      def results
        new_results = generate
        @@previous_coverage = current_coverage
        new_results
      end

      def self.reset
        @@previous_coverage = {}
        @@project_directory = File.expand_path(Coverband.configuration.root)
        @@ignore_patterns = Coverband.configuration.ignore
      end

      private

      def generate
        current_coverage.each_with_object({}) do |(file, current_file_coverage_data), new_results|
          ###
          # Eager filter:
          # Normally I would break this out into additional methods
          # and improve the readability but this is in a tight loop
          # on the critical performance path, and any refactoring I come up with
          # would slow down the performance.
          ###
          next unless @@ignore_patterns.none? { |pattern| file.match(pattern) } &&
            file.start_with?(@@project_directory)

          previous_file_coverage_data = @@previous_coverage[file]

          if previous_file_coverage_data.nil?
            new_results[file] = current_file_coverage_data
          else
            if current_file_coverage_data.is_a?(Hash) && current_file_coverage_data.key?(:methods)
              # Methods coverage format: { methods: {...} }
              current_methods = current_file_coverage_data[:methods] # Hash: { method_id_array => count }

              prev_methods_hash = nil
              if previous_file_coverage_data.is_a?(Hash) && previous_file_coverage_data.key?(:methods)
                prev_methods_hash = previous_file_coverage_data[:methods]
              end
              
              diffed_methods = nil
              if current_methods.is_a?(Hash)
                diffed_methods = {}
                current_methods.each do |method_id, current_count|
                  prev_count = prev_methods_hash ? (prev_methods_hash[method_id] || 0) : 0
                  # Ensure counts are integers before subtraction
                  diff_val = current_count.to_i - prev_count.to_i
                  diff_count = [0, diff_val].max # Ensure non-negative
                  diffed_methods[method_id] = diff_count if diff_count > 0
                end
                diffed_methods = nil if diffed_methods.empty?
              end

              # Only add to new_results if there's actual method coverage to report
              has_method_coverage = diffed_methods && !diffed_methods.empty?

              if has_method_coverage
                new_results[file] = { methods: diffed_methods }
              end
            else
              # Unknown format, skip
              next
            end
          end
        end
      end

      def array_diff(latest, original)
        latest.map.with_index do |v, i|
          [0, v - original[i]].max if v && original[i]
        end
      end
    end
  end
end
