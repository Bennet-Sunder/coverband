# frozen_string_literal: true

module Coverband
  module Collectors
    class TracepointMethodTracker
      # Patterns to ignore (Rails, gems, framework code)
      IGNORE_PATTERNS = [
        /gems\//, /vendor\//, /lib\/rails\//, /lib\/active_record\//,
        /lib\/action_controller\//, /lib\/action_view\//, /lib\/active_support\//,
        /lib\/rack\//, /lib\/bundler\//, /lib\/rake\//, /tmp\//, /log\//,
        /public\//, /node_modules\//, /\.git\//, /\.bundle\//, /.rvm\/rubies/
      ]

      class << self
        def setup_global_tracepoint
          return if @tracepoint_enabled

          @tracepoint = TracePoint.new(:call) do |tp|
            # Only track if current thread has test_case_id
            test_case_data = Thread.current[:coverband_test_case_id]
            next unless test_case_data

            # Skip if method should be ignored
            next if ignore_method?(tp)

            # Record method call to thread-local storage
            record_method_call(tp)
          end

          @tracepoint.enable
          @tracepoint_enabled = true

          Coverband.configuration.logger&.info("Coverband: Global TracePoint method tracker enabled")
        end

        def disable_global_tracepoint
          return unless @tracepoint_enabled

          @tracepoint&.disable
          @tracepoint = nil
          @tracepoint_enabled = false

          Coverband.configuration.logger&.info("Coverband: Global TracePoint method tracker disabled")
        end

        def tracepoint_enabled?
          @tracepoint_enabled
        end

        def save_tracepoint_coverage(test_case_data, method_calls)
          test_case_data&.deep_symbolize_keys!
          return if method_calls.empty?

          # Convert method calls to Coverband format
          coverage_data = convert_method_calls_to_coverage(method_calls)
          
          # Save to Coverband store
          Coverband.configuration.store.processor.process_coverage_data(
            test_case_data[:test_id] || test_case_data['test_id'],
            test_case_data,
            coverage_data
          )

          puts "Coverband: Saved #{method_calls.length} method calls for job #{test_case_data[:jid]}"
        end

        private

        def ignore_method?(tp)
          return true unless tp.path
          
          # Ignore internal Ruby methods
          return true if tp.path.start_with?('<internal:')
          
          # Ignore framework patterns
          return true if IGNORE_PATTERNS.any? { |pattern| tp.path.match?(pattern) }
          return true if tp.path.include?('coverband') # Ignore Coverband itself
          return true if tp.path.include?('tracepoint_method_tracker.rb') # Ignore this file
          
          # Ignore common framework paths
          return true if tp.path.include?('/gems/')
          return true if tp.path.include?('/vendor/')
          return true if tp.path.include?('/lib/rails/')
          return true if tp.path.include?('/lib/active_record/')
          return true if tp.path.include?('/lib/action_controller/')
          return true if tp.path.include?('/lib/action_view/')
          return true if tp.path.include?('/lib/active_support/')
          return true if tp.path.include?('/lib/rack/')
          return true if tp.path.include?('/lib/bundler/')
          return true if tp.path.include?('/lib/rake/')
          return true if tp.path.include?('/tmp/')
          return true if tp.path.include?('/log/')
          return true if tp.path.include?('/public/')
          return true if tp.path.include?('/node_modules/')
          return true if tp.path.include?('/.git/')
          return true if tp.path.include?('/.bundle/')
          
          # Ignore common Ruby standard library paths
          return true if tp.path.include?('/ruby/')
          return true if tp.path.include?('/lib/ruby/')
          
          # Ignore nil class methods (internal Ruby methods)
          return true if tp.defined_class.nil?
          
          # Ignore very common methods that add noise
          return true if %i[class to_s to_sym to_i to_f to_a to_h inspect].include?(tp.method_id)
          
          false
        end

        def record_method_call(tp)
          # Use thread-local storage
          Thread.current[:method_calls] ||= []

          # Record method call
          Thread.current[:method_calls] << {
            method: tp.method_id,
            file: tp.path,
            class: tp.defined_class.name
          }
        end

        def convert_method_calls_to_coverage(method_calls)
          # Group method calls by file
          by_file = method_calls.group_by { |call| call[:file] }
          coverage_data = []
          by_file.each do |file, calls|
            # Create method coverage hash
            calls.each do |call|
              coverage_data << {
                file_path: call[:file] || call['file'],
                class_name: call[:class] || call['class'],
                method_name: call[:method] || call['method'],
                full_method_name: "#{call[:class] || call['class']}##{call[:method] || call['method']}"
              }
            end
          end
          
          coverage_data
        end
      end
    end
  end
end 