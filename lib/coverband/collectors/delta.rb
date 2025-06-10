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
          if Coverband.configuration.use_oneshot_lines_coverage
            ::Coverage.result(clear: true, stop: false)
          else
            ::Coverage.peek_result
          end
        end
      end

      def self.results(process_coverage = RubyCoverage)
        coverage_results = process_coverage.results
        new(coverage_results).results
      end

      def results
        if Coverband.configuration.use_oneshot_lines_coverage
          transform_oneshot_lines_results(current_coverage)
        else
          new_results = generate
          @@previous_coverage = current_coverage
          new_results
        end
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

          if current_file_coverage_data.is_a?(Hash) && current_file_coverage_data.key?(:lines)
            # New format: { lines: [...], methods: {...} }
            current_lines = current_file_coverage_data[:lines]
            current_methods = current_file_coverage_data[:methods] # Hash: { method_id_array => count }

            prev_lines_arr = nil
            prev_methods_hash = nil
            if previous_file_coverage_data.is_a?(Hash) && previous_file_coverage_data.key?(:lines)
              prev_lines_arr = previous_file_coverage_data[:lines]
              prev_methods_hash = previous_file_coverage_data[:methods]
            elsif previous_file_coverage_data.is_a?(Array) # legacy, only lines
              prev_lines_arr = previous_file_coverage_data
            end

            diffed_lines = prev_lines_arr ? array_diff(current_lines, prev_lines_arr) : current_lines
            
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

            # Only add to new_results if there's actual coverage to report
            has_line_coverage = diffed_lines&.any? { |c| c&.positive? }
            has_method_coverage = diffed_methods && !diffed_methods.empty?

            if has_line_coverage || has_method_coverage
              new_results[file] = { lines: diffed_lines || [] } # Ensure lines is always an array
              new_results[file][:methods] = diffed_methods if has_method_coverage
            end
          else
            # Legacy format or lines-only: current_file_coverage_data is an Array
            arr_line_counts = current_file_coverage_data
            
            prev_line_counts_arr_legacy = nil
            if previous_file_coverage_data # Check if previous data exists
              if previous_file_coverage_data.is_a?(Hash) && previous_file_coverage_data.key?(:lines)
                prev_line_counts_arr_legacy = previous_file_coverage_data[:lines]
              elsif previous_file_coverage_data.is_a?(Array)
                prev_line_counts_arr_legacy = previous_file_coverage_data
              end
            end
            
            result_lines = prev_line_counts_arr_legacy ? array_diff(arr_line_counts, prev_line_counts_arr_legacy) : arr_line_counts
            
            if result_lines&.any? { |c| c&.positive? }
              new_results[file] = result_lines
            end
          end
        end
      end

      def array_diff(latest, original)
        latest.map.with_index do |v, i|
          [0, v - original[i]].max if v && original[i]
        end
      end

      def transform_oneshot_lines_results(results)
        results.each_with_object({}) do |(file, coverage), new_results|
          ###
          # Eager filter:
          # Normally I would break this out into additional methods
          # and improve the readability but this is in a tight loop
          # on the critical performance path, and any refactoring I come up with
          # would slow down the performance.
          ###
          next unless @@ignore_patterns.none? { |pattern| file.match(pattern) } &&
            file.start_with?(@@project_directory)

          @@stubs[file] ||= ::Coverage.line_stub(file)
          transformed_line_counts = coverage[:oneshot_lines].each_with_object(@@stubs[file].dup) { |line_number, line_counts|
            line_counts[line_number - 1] = 1
          }
          new_results[file] = transformed_line_counts
        end
      end
    end
  end
end
