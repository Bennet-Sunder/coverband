# frozen_string_literal: true

require "securerandom"

module Coverband
  module Adapters
    class HashRedisStore < Base
      FILE_KEY = "file"
      FILE_LENGTH_KEY = "file_length"
      META_DATA_KEYS = [DATA_KEY, FIRST_UPDATED_KEY, LAST_UPDATED_KEY, FILE_HASH].freeze
      ###
      # This key isn't related to the coverband version, but to the internal format
      # used to store data to redis. It is changed only when breaking changes to our
      # redis format are required.
      ###
      REDIS_STORAGE_FORMAT_VERSION = "coverband_hash_4_0"
      METHOD_STORAGE_KEY_SEGMENT = "methods" # New constant for method key segment
      TEST_CASE_METHOD_SEPARATOR = "::TEST::" # New constant for test case separator in method fields

      JSON_PAYLOAD_EXPIRATION = 5 * 60

      # Constants for optimized request-based storage
      REQUEST_TRACE_KEY = "coverband_request"
      WORKER_TRACE_KEY = "coverband_worker"
      TEST_CASE_MAP_KEY = "coverband_test_case"
      TEST_CASE_INDEX_KEY = "coverband_test_cases"
      TEST_CASE_EXPIRATION = 12 * 60 * 60 # 12 hours in seconds (changed from 7 days)

      attr_reader :redis_namespace

      def initialize(redis, opts = {})
        super()
        @redis_namespace = opts[:redis_namespace]
        @save_report_batch_size = opts[:save_report_batch_size] || 100
        @format_version = REDIS_STORAGE_FORMAT_VERSION
        @redis = redis
        raise "HashRedisStore requires redis >= 2.6.0" unless supported?

        @ttl = opts[:ttl]
        @relative_file_converter = opts[:relative_file_converter] || Utils::RelativeFileConverter
      end

      def supported?
        Gem::Version.new(@redis.info["redis_version"]) >= Gem::Version.new("2.6.0")
      rescue Redis::CannotConnectError => e
        Coverband.configuration.logger.info "Redis is not available (#{e}), Coverband not configured"
        Coverband.configuration.logger.info "If this is a setup task like assets:precompile feel free to ignore"
      end

      def clear!
        old_type = type
        Coverband::TYPES.each do |type|
          self.type = type
          # Clear line coverage data
          line_file_keys = files_set # Gets keys for current type
          @redis.del(*line_file_keys) if line_file_keys.any?
          @redis.del(files_key) # Deletes the set itself for line coverage

          # Clear method coverage data
          method_file_keys = method_files_set # Gets method keys for current type
          @redis.del(*method_file_keys) if method_file_keys.any?
          @redis.del(method_files_key) # Deletes the set itself for method coverage
        end
        self.type = old_type
      end

      def clear_file!(file)
        file_hash = file_hash(file)
        relative_path_file = @relative_file_converter.convert(file)
        Coverband::TYPES.each do |current_type|
          # Clear line coverage for the file
          line_key = key(relative_path_file, current_type, file_hash: file_hash)
          @redis.del(line_key)
          @redis.srem(files_key(current_type), line_key) # Remove from the set of line-covered files

          # Clear method coverage for the file
          method_key_for_file = method_coverage_key(relative_path_file, current_type, file_hash)
          @redis.del(method_key_for_file)
          @redis.srem(method_files_key(current_type), method_key_for_file) # Remove from the set of method-covered files
        end
      end

      # Save report data with an associated test case details hash
      # @param report [Hash] Coverage report data
      # @param test_case_details [Hash] Hash containing test case information
      def save_method_report(report, test_case_details = nil)
        return if report.nil? || report.empty?
        test_case_details.symbolize_keys!
        # If no test case details provided, just return
        return unless test_case_details.is_a?(Hash) && test_case_details[:test_id]
        
        # Extract test case information
        test_id = test_case_details[:test_id]
        action_type = test_case_details[:action_type]
        action_url = test_case_details[:action_url]
        response_code = test_case_details[:response_code]
        
        # Extract method coverage data from the report
        method_trace = extract_method_coverage(report)
        return if method_trace.empty?
        
        # Create a request_id for HTTP requests or use worker_id for background jobs
        if test_case_details[:worker_class]
          # This is a worker
          worker_class = test_case_details[:worker_class]
          entity_id = "worker::#{worker_class}"
          entity_type = WORKER_TRACE_KEY
        else
          # This is a request
          # Create a consistent request ID using available information
          entity_id = "#{test_id}::#{action_type || 'UNKNOWN'}::#{action_url || 'UNKNOWN'}::#{response_code || 'UNKNOWN'}"
          entity_type = REQUEST_TRACE_KEY
        end
        
        # Generate keys
        entity_key = "#{entity_type}:#{entity_id}"
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_id}"
        sizes_key = "#{entity_type}:sizes"
        
        # Prepare data
        trace_json = method_trace.to_json
        json_size_bytes = trace_json.bytesize.to_s
        
        # Use Lua script to ensure atomicity of core operations
        begin
          # Get or load the script SHA (will load the script if not already loaded)
          lua_sha = save_method_trace_script_sha
          
          # Execute the Lua script which performs all operations atomically
          @redis.evalsha(
            lua_sha,
            keys: [entity_key, sizes_key, TEST_CASE_INDEX_KEY, test_case_key],
            argv: [trace_json, entity_id, test_id, TEST_CASE_EXPIRATION.to_s, json_size_bytes]
          )
          
          return true
        rescue Redis::CommandError => e
          Rails.logger.error("Coverband: Redis error saving method trace: #{e.message}")
          return false
        rescue => e
          Rails.logger.error("Coverband: Unexpected error saving method trace: #{e.class} - #{e.message}")
          return false
        end
      end
      
      # Get the SHA for the save_method_trace Lua script
      # @return [String] SHA of the Lua script
      def save_method_trace_script_sha
        @save_method_trace_script_sha ||= load_save_method_trace_script
      end
      
      # Load the save_method_trace Lua script into Redis
      # @return [String] SHA of the loaded script
      def load_save_method_trace_script
        lua_script_path = File.join(
          File.dirname(__FILE__), "../../../lua/lib/persist-method-trace.lua"
        )
        lua_script = File.read(lua_script_path)
        @save_method_trace_script_sha = @redis.script(:load, lua_script)
      end
      
      # Extract method coverage from report data
      # @param report [Hash] Coverage report data
      # @return [Hash] Method coverage data by file
      def extract_method_coverage(report)
        method_trace = {}
        
        report.each do |file_path, coverage_data|
          next unless coverage_data.is_a?(Hash) && coverage_data.key?(:methods)
          
          methods = coverage_data[:methods]
          next if methods.nil? || methods.empty?
          
          executed_methods = methods.select { |_, count| count && count > 0 }
          next if executed_methods.empty?
          
          # Convert method identifiers to method names
          method_names = executed_methods.keys.map do |method_ident|
            if method_ident.is_a?(Array) && method_ident.length >= 2
              construct_method_fullname(method_ident)
            end
          end.compact
          
          relative_path = @relative_file_converter.convert(file_path)
          method_trace[relative_path] = method_names if method_names.any?
        end
        
        method_trace
      end
      
      # Save method trace data for an entity (request or worker)
      # @param entity_type [String] The entity type key
      # @param entity_id [String] The entity identifier
      # @param method_trace [Hash] Method trace data
      def save_entity_method_trace(entity_type, entity_id, method_trace)
        return if method_trace.empty?
        
        entity_key = "#{entity_type}:#{entity_id}"
        trace_json = method_trace.to_json
        json_size_bytes = trace_json.bytesize
        
        @redis.set(entity_key, trace_json, ex: TEST_CASE_EXPIRATION)
        @redis.hset("#{entity_type}:sizes", entity_id, json_size_bytes.to_s)
      end
      
      # Associate an entity with a test case
      # @param test_case_id [String] The test case identifier
      # @param entity_id [String] The entity identifier
      def associate_with_test_case(test_case_id, entity_id)
        return if test_case_id.nil? || entity_id.nil?
        
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        
        # Add test case to index
        @redis.sadd(TEST_CASE_INDEX_KEY, test_case_id)
        
        # Add entity to test case's set
        @redis.sadd(test_case_key, entity_id)
        
        # Set TTL for test case set
        @redis.expire(test_case_key, TEST_CASE_EXPIRATION)
      end
      
      # Get method trace for a test case by combining all associated entities
      # @param test_case_id [String] The test case identifier
      # @return [Hash] Combined method trace for the test case
      def get_test_case_method_trace(test_case_id)
        return {} if test_case_id.nil?
        
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        entity_ids = @redis.smembers(test_case_key)
        return {} if entity_ids.empty?
        
        combined_trace = {}
        
        entity_ids.each do |entity_id|
          entity_key = if entity_id.start_with?("worker::")
                        "#{WORKER_TRACE_KEY}:#{entity_id}"
                      else
                        "#{REQUEST_TRACE_KEY}:#{entity_id}"
                      end
          
          trace_json = @redis.get(entity_key)
          next unless trace_json
          
          begin
            trace = JSON.parse(trace_json)
            
            # Merge this trace into the combined trace
            trace.each do |file, methods|
              combined_trace[file] ||= []
              methods.each do |method|
                combined_trace[file] << method unless combined_trace[file].include?(method)
              end
            end
          rescue JSON::ParserError => e
            Rails.logger.error("Coverband: Error parsing JSON for entity #{entity_id}: #{e.message}")
          end
        end
        
        combined_trace
      end
      
      # Extract test case method coverage data directly from Redis
      # Returns a structure that matches the format expected by the test impact analysis tools
      # @param test_case_ids [Array<String>] Optional list of test case IDs to extract (default: all)
      # @return [Hash] Format: { test_case_id => { entity_id => { file_path => [method_names] } } }
      def extract_test_case_method_coverage(test_case_ids = nil)
        # Get all test case IDs if not specified
        all_test_case_ids = @redis.smembers(TEST_CASE_INDEX_KEY)
        
        # Filter by test case IDs if specified
        test_case_ids = test_case_ids ? all_test_case_ids.select { |id| test_case_ids.include?(id) } : all_test_case_ids
        
        result = {}
        
        test_case_ids.each do |test_case_id|
          test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
          entity_ids = @redis.smembers(test_case_key)
          
          next if entity_ids.empty?
          result[test_case_id] = {}
          
          entity_ids.each do |entity_id|
            # Determine if this is a request or worker entity
            if entity_id.start_with?("worker::")
              entity_key = "#{WORKER_TRACE_KEY}:#{entity_id}"
            else
              entity_key = "#{REQUEST_TRACE_KEY}:#{entity_id}"
            end
            
            # Get the trace JSON for this entity
            trace_json = @redis.get(entity_key)
            next unless trace_json
            
            begin
              # Parse the trace data (mapping of file paths to method names)
              trace_data = JSON.parse(trace_json)
              
              # Store this entity's data
              result[test_case_id][entity_id] = {}
              
              # Add file paths and methods to the result
              trace_data.each do |file_path, methods|
                # Ensure file path has the expected format
                formatted_file_path = file_path.start_with?('./') ? file_path : "./#{file_path}"
                result[test_case_id][entity_id][formatted_file_path] = methods
              end
            rescue JSON::ParserError => e
              Coverband.configuration.logger.warn "Coverband: Error parsing JSON for entity #{entity_id}: #{e.message}"
            end
          end
          
          # Remove test case if it has no entities with valid data
          result.delete(test_case_id) if result[test_case_id].empty?
        end
        
        result
      end
      
      # Alias to maintain backward compatibility
      alias_method :original_save_report, :save_report unless method_defined?(:original_save_report)
      
      # Get coverage with test case mapping
      # This method is called from the reporter
      def coverage(type = nil, options = {})
        if options[:test_case_map] && options[:method_coverage]
          # Handle method coverage with test case mapping
          test_case_method_coverage = {}
          
          list_test_case_ids.each do |test_case_id|
            test_case_method_coverage[test_case_id] = get_test_case_method_trace(test_case_id)
          end
          
          return test_case_method_coverage
        end
        
        # Fall back to standard coverage for other cases
        super
      end

      def clear!
        old_type = type
        Coverband::TYPES.each do |type|
          self.type = type
          # Clear line coverage data
          line_file_keys = files_set # Gets keys for current type
          @redis.del(*line_file_keys) if line_file_keys.any?
          @redis.del(files_key) # Deletes the set itself for line coverage

          # Clear method coverage data
          method_file_keys = method_files_set # Gets method keys for current type
          @redis.del(*method_file_keys) if method_file_keys.any?
          @redis.del(method_files_key) # Deletes the set itself for method coverage
        end
        self.type = old_type
      end

      def clear_file!(file)
        file_hash = file_hash(file)
        relative_path_file = @relative_file_converter.convert(file)
        Coverband::TYPES.each do |current_type|
          # Clear line coverage for the file
          line_key = key(relative_path_file, current_type, file_hash: file_hash)
          @redis.del(line_key)
          @redis.srem(files_key(current_type), line_key) # Remove from the set of line-covered files

          # Clear method coverage for the file
          method_key_for_file = method_coverage_key(relative_path_file, current_type, file_hash)
          @redis.del(method_key_for_file)
          @redis.srem(method_files_key(current_type), method_key_for_file) # Remove from the set of method-covered files
        end
      end

      def save_report(report, test_case_id = nil)
        report_time = Time.now.to_i
        current_store_type = type
        updated_time_for_lines = (current_store_type == Coverband::EAGER_TYPE) ? report_time.to_s : report_time.to_s

        # Prepare batches for Lua scripts
        line_coverage_batches = []
        method_coverage_batches = []

        # Ensure Lua script SHAs are loaded and are strings BEFORE any pipelining on @redis starts
        # for this save_report operation. This prevents @redis.script(:load) from being called
        # when @redis is in a pipelined state for this block, which would result in a Redis::Future.
        loaded_hash_incr_script_sha = hash_incr_script
        loaded_method_hash_incr_script_sha = method_hash_incr_script_sha

        # Optional: Validate SHAs to ensure they are strings.
        unless loaded_hash_incr_script_sha.is_a?(String) && loaded_method_hash_incr_script_sha.is_a?(String)
          Coverband.configuration.logger.error("Coverband: Critical error - Lua script SHAs were not loaded as strings. " +
            "hash_sha: #{loaded_hash_incr_script_sha.inspect}, method_sha: #{loaded_method_hash_incr_script_sha.inspect}. " +
            "Coverage data may not be saved correctly.")
          # Consider returning or raising an error if SHAs are not loaded,
          # as proceeding will likely lead to errors.
        end

        report.each do |file_full_path, coverage_data_for_file|
          relative_file = @relative_file_converter.convert(file_full_path)
          current_file_content_hash = file_hash(file_full_path)

          lines_data_array = nil
          methods_data_hash = nil # Expected: { [method_ident_array] => count }

          if coverage_data_for_file.is_a?(Hash) && coverage_data_for_file.key?(:lines)
            lines_data_array = coverage_data_for_file[:lines]
            methods_data_hash = coverage_data_for_file[:methods]
          elsif coverage_data_for_file.is_a?(Array)
            lines_data_array = coverage_data_for_file # Legacy or lines-only
          end

          # 1. Prepare line coverage data for its Lua script
          if lines_data_array && lines_data_array.any? { |c| c&.positive? }
            line_key_for_lua = key(relative_file, file_hash: current_file_content_hash)
            line_coverage_batches << {
              key: line_key_for_lua,
              file: relative_file,
              file_hash: current_file_content_hash,
              data: lines_data_array,
              report_time: report_time,
              updated_time: updated_time_for_lines,
              test_case_id: test_case_id # Pass test_case_id for line script
            }
          end
          # 2. Prepare method coverage data for its Lua script
          Rails.logger.info "Coverband: methods_data_hash #{methods_data_hash}"
          if methods_data_hash && methods_data_hash.any? { |_method_arr, count| count&.positive? }
            method_key_for_lua = method_coverage_key(relative_file, current_store_type, current_file_content_hash)
            
            # Construct the method_coverage_payload for the Lua script
            method_coverage_payload = {}
            methods_data_hash.each do |method_ident_array, count|
              next unless count&.positive?
              method_fullname = construct_method_fullname(method_ident_array)
              next if method_fullname.nil? || method_fullname.empty?
              method_coverage_payload[method_fullname] = count.to_i
            end
            Rails.logger.info "Coverband: method_coverage_payload #{method_coverage_payload}"
            if method_coverage_payload.any?
              method_coverage_batches << {
                key: method_key_for_lua,
                meta: {
                  file: relative_file,
                  file_hash: current_file_content_hash,
                  first_updated_at: report_time.to_s,
                  last_updated_at: report_time.to_s # Lua script handles first_updated_at logic
                },
                coverage: method_coverage_payload,
                test_case_id: test_case_id ? test_case_id.to_s : "", # Pass test_case_id for method script
                ttl: @ttl
              }
            end
          end
        end

        # Execute Lua script for line coverage batches
        line_keys_for_sadd = []
        line_coverage_batches.each_slice(@save_report_batch_size) do |batch_slice|
          # The existing script_input and lua execution for lines expects a slightly different structure
          # It wraps multiple files' data into one JSON payload for ARGV[0] of lua script.
          # We need to adapt or call it per file if that's simpler, or batch appropriately.
          # For now, let's assume we process one file at a time for line_coverage_batches to simplify adaptation.
          # This might be less efficient than the original batching if save_report_batch_size was > 1 for lines.
          # Revisit batching for lines if performance is an issue.
          
          files_data_for_line_lua = batch_slice.map do |item|
            line_keys_for_sadd << item[:key]
            script_input(
              key: item[:key],
              file: item[:file],
              file_hash: item[:file_hash],
              data: item[:data],
              report_time: item[:report_time],
              updated_time: item[:updated_time]
              # test_case_id is passed as a separate arg to EVALSHA for the line script
            )
          end

          if files_data_for_line_lua.any?
            lua_arguments_key = [@redis_namespace, SecureRandom.uuid].compact.join(".")
            lua_payload_for_lines = {ttl: @ttl, files_data: files_data_for_line_lua}.to_json
            
            Rails.logger.info "Coverband: lua_payload_for_lines #{lua_payload_for_lines}"
            @redis.set(lua_arguments_key, lua_payload_for_lines, ex: JSON_PAYLOAD_EXPIRATION)
            # The line script takes report_time and test_case_id as separate ARGV items
            # We need to ensure the test_case_id from the first item in batch_slice is representative if batching > 1
            # Or, if test_case_id can vary per file in a batch, this needs careful handling.
            # Assuming test_case_id is uniform for the save_report call.
            lua_test_case_id_arg = test_case_id ? test_case_id.to_s : ""
            Rails.logger.info "Coverband: lua_test_case_id_arg #{lua_test_case_id_arg}"
            # Lua script handles first_updated_at internally if the key is new.
            # It always sets last_updated_at from ARGV[1] (report_time from script_input's updated_time).
            @redis.evalsha(loaded_hash_incr_script_sha, [lua_arguments_key], [report_time.to_s, lua_test_case_id_arg]) # <-- Corrected: use the local variable
          end
        end
        @redis.sadd(files_key(current_store_type), line_keys_for_sadd.uniq) if line_keys_for_sadd.any?

        # Execute Lua script for method coverage batches
        method_keys_for_sadd = []
        method_coverage_batches.each_slice(@save_report_batch_size) do |batch_slice|
          @redis.pipelined do |pipeline|
            batch_slice.each do |item|
              method_keys_for_sadd << item[:key]
              payload_json = item.except(:key).to_json
              # Use the pre-loaded SHA string for method coverage
              pipeline.evalsha(loaded_method_hash_incr_script_sha, [item[:key]], [payload_json])
            end
          end
        end
        @redis.sadd(method_files_key(current_store_type), method_keys_for_sadd.uniq) if method_keys_for_sadd.any?
      end

      # NOTE: This method should be used for full coverage or filename coverage look ups
      # When paging code should use coverage_for_types and pull eager and runtime together as matched pairs
      def coverage(local_type = nil, opts = {})
        page_size = opts[:page_size] || 250
        
        # Return method test case mapping data if method_test_case_map is true
        if opts[:test_case_map] && opts[:method_coverage]
          return method_coverage(local_type, test_case_map: true)
        end
        
        # Determine the set of Redis keys to fetch based on options
        keys_to_fetch = if opts[:page]
          raise "call coverage_for_types with paging" # Paging should use a different path
        elsif opts[:filename]
          type_key_prefix = key_prefix(local_type)
          files_set(local_type).select do |cache_key|
            # A more robust way to extract filename might be needed if keys change format
            cache_key.sub(type_key_prefix, "").match(short_name(opts[:filename]))
          end || [] # Ensure it's an array
        else
          files_set(local_type)
        end

        # Fetch data from Redis in batches
        # files_data_from_redis will be an array of hashes, each hash from HGETALL
        files_data_from_redis = keys_to_fetch.each_slice(page_size).flat_map do |key_batch|
          sleep(0.01 * rand(1..10)) # Avoid overloading Redis
          @redis.pipelined do |pipeline|
            key_batch.each do |key|
              pipeline.hgetall(key)
            end
          end
        end

        if opts[:test_case_map]
          # The add_test_case_map method now directly populates the accumulator
          # with the final desired structure:
          # { original_test_case_id => { request_id => { file_name => [line_numbers] } } }
          processed_test_case_data = {}
          files_data_from_redis.each do |hash_from_redis|
            add_test_case_map(processed_test_case_data, hash_from_redis)
          end

          # Sort line numbers for each file within each request_id's data
          processed_test_case_data.each_value do |requests_map|
            requests_map.each_value do |files_and_lines_map|
              files_and_lines_map.each_value do |line_numbers_array|
                line_numbers_array.sort!
              end
            end
          end
          processed_test_case_data
        else
          # Original logic for non-test_case_map requests
          files_data_from_redis.each_with_object({}) do |data_from_redis, hash|
            add_coverage_for_file(data_from_redis, hash)
          end
        end
      end

      def split_coverage(types, coverage_cache, options = {})
        if types.is_a?(Array) && !options[:filename] && options[:page]
          data = coverage_for_types(types, options)
          coverage_cache[Coverband::RUNTIME_TYPE] = data[Coverband::RUNTIME_TYPE]
          coverage_cache[Coverband::EAGER_TYPE] = data[Coverband::EAGER_TYPE]
          data
        else
          super
        end
      end

      def coverage_for_types(_types, opts = {})
        page_size = opts[:page_size] || 250
        hash_data = {}

        runtime_file_set = files_set(Coverband::RUNTIME_TYPE)
        @cached_file_count = runtime_file_set.length
        runtime_file_set = runtime_file_set.each_slice(page_size).to_a[opts[:page] - 1] || []

        hash_data[Coverband::RUNTIME_TYPE] = runtime_file_set.each_slice(page_size).flat_map do |key_batch|
          @redis.pipelined do |pipeline|
            key_batch.each do |key|
              pipeline.hgetall(key)
            end
          end
        end

        # NOTE: This is kind of hacky, we find all the matching eager loading data
        # for current page of runtime data.

        eager_key_pre = key_prefix(Coverband::EAGER_TYPE)
        runtime_key_pre = key_prefix(Coverband::RUNTIME_TYPE)
        matched_file_set = runtime_file_set.map do |runtime_key|
          runtime_key.sub(runtime_key_pre, eager_key_pre)
        end

        hash_data[Coverband::EAGER_TYPE] = matched_file_set.each_slice(page_size).flat_map do |key_batch|
          @redis.pipelined do |pipeline|
            key_batch.each do |key|
              pipeline.hgetall(key)
            end
          end
        end

        hash_data[Coverband::RUNTIME_TYPE] = hash_data[Coverband::RUNTIME_TYPE].each_with_object({}) do |data_from_redis, hash|
          add_coverage_for_file(data_from_redis, hash)
        end
        hash_data[Coverband::EAGER_TYPE] = hash_data[Coverband::EAGER_TYPE].each_with_object({}) do |data_from_redis, hash|
          add_coverage_for_file(data_from_redis, hash)
        end
        hash_data
      end

      def short_name(filename)
        filename.sub(/^#{Coverband.configuration.root}/, ".")
          .gsub(%r{^\./}, "")
      end

      def file_count(local_type = nil)
        files_set(local_type).count { |filename| !Coverband.configuration.ignore.any? { |i| filename.match(i) } }
      end

      def cached_file_count
        @cached_file_count ||= file_count(Coverband::RUNTIME_TYPE)
      end

      def raw_store
        @redis
      end

      def size
        "not available"
      end

      def size_in_mib
        "not available"
      end

      def method_coverage(local_type = nil, opts = {})
        page_size = opts[:page_size] || 250
        # Determine the set of Redis keys to fetch based on options
        keys_to_fetch = if opts[:page]
          raise "Paging not supported for method_coverage" 
        elsif opts[:filename]
          type_key_prefix = key_prefix(local_type)
          method_files_set(local_type).select do |cache_key|
            # Extract filename from method coverage key
            cache_key.sub(type_key_prefix, "").sub(".#{METHOD_STORAGE_KEY_SEGMENT}.", "").match(short_name(opts[:filename]))
          end || [] # Ensure it's an array
        else
          method_files_set(local_type)
        end

        # Fetch method coverage data from Redis in batches
        method_data_from_redis = keys_to_fetch.each_slice(page_size).flat_map do |key_batch|
          sleep(0.01 * rand(1..10)) # Avoid overloading Redis
          @redis.pipelined do |pipeline|
            key_batch.each do |key|
              pipeline.hgetall(key)
            end
          end
        end

        if opts[:test_case_map]
          # Process method test case mapping data
          processed_test_case_data = {}
          method_data_from_redis.each do |hash_from_redis|
            add_method_test_case_map(processed_test_case_data, hash_from_redis)
          end
          
          # Sort method names for each file (for consistency with line test case map)
          processed_test_case_data.each_value do |requests_map|
            requests_map.each_value do |files_and_methods_map|
              files_and_methods_map.each_value do |method_names_array|
                method_names_array.sort!
              end
            end
          end
          
          processed_test_case_data
        else
          # Return regular method coverage data
          method_data_from_redis.each_with_object({}) do |data_from_redis, hash|
            next if data_from_redis.empty?
            
            file = data_from_redis[FILE_KEY]
            next unless file_hash(file) == data_from_redis[FILE_HASH]
            
            # Extract method coverage data
            method_coverage = {}
            data_from_redis.each do |key, value|
              # Skip metadata fields
              next if META_DATA_KEYS.include?(key) || key == FILE_KEY || key == FILE_LENGTH_KEY || key == 'test_cases'
              
              # Method keys are the actual method names/identifiers
              method_coverage[key] = value.to_i
            end
            
            hash[file] = {
              "file_hash" => data_from_redis[FILE_HASH],
              "first_updated_at" => data_from_redis[FIRST_UPDATED_KEY]&.to_i,
              "last_updated_at" => data_from_redis[LAST_UPDATED_KEY]&.to_i,
              "methods" => method_coverage
            }
          end
        end
      end

      # Clear all method coverage related keys from Redis
      # @param test_case_ids [Array<String>] Optional list of test case IDs to clear (default: all)
      # @return [Integer] Number of keys cleared
      def clear_method_coverage!(test_case_ids = nil)
        keys_cleared = 0
        
        if test_case_ids.nil? || test_case_ids.empty?
          # For small to medium-sized datasets, we can use KEYS + DEL
          # For very large datasets, consider using Lua script with SCAN + DEL for better performance
          
          # Use Lua script to efficiently delete keys by pattern
          # This is more efficient than collecting keys first, then deleting them
          lua_script = <<~LUA
            local cursor = "0"
            local matched_keys = {}
            local total_deleted = 0
            local pattern = ARGV[1]
            
            repeat
              local result = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", 1000)
              cursor = result[1]
              local keys = result[2]
              
              if #keys > 0 then
                total_deleted = total_deleted + redis.call("DEL", unpack(keys))
              end
            until cursor == "0"
            
            return total_deleted
          LUA
          
          # Delete request trace keys
          keys_cleared += @redis.eval(lua_script, [], ["#{REQUEST_TRACE_KEY}:*"])
          
          # Delete worker trace keys
          keys_cleared += @redis.eval(lua_script, [], ["#{WORKER_TRACE_KEY}:*"])
          
          # Delete test case keys
          keys_cleared += @redis.eval(lua_script, [], ["#{TEST_CASE_MAP_KEY}:*"])
          
          # Delete the size hash keys - direct deletion is fine for known keys
          keys_cleared += @redis.del("#{REQUEST_TRACE_KEY}:sizes", "#{WORKER_TRACE_KEY}:sizes", TEST_CASE_INDEX_KEY)
          
          # Clear all method_files keys and their contents for each type
          Coverband::TYPES.each do |current_type|
            method_files_key_name = method_files_key(current_type)
            method_files = @redis.smembers(method_files_key_name)
            
            # Delete all method files in batches if there are any
            if method_files.any?
              method_files.each_slice(500) do |keys_batch|
                keys_cleared += @redis.del(*keys_batch)
              end
            end
            
            # Delete the method files key itself
            keys_cleared += @redis.del(method_files_key_name)
          end
        else
          # Selective deletion for specific test case IDs
          test_case_ids.each do |test_case_id|
            test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
            
            # Get all entity IDs for this test case
            entity_ids = @redis.smembers(test_case_key)
            
            # Delete entity keys and update size hashes in one batch operation
            if entity_ids.any?
              # Group entity IDs by type
              worker_ids = entity_ids.select { |id| id.start_with?("worker::") }
              request_ids = entity_ids - worker_ids
              
              # Create entity keys for deletion
              entity_keys = []
              entity_keys.concat(worker_ids.map { |id| "#{WORKER_TRACE_KEY}:#{id}" }) if worker_ids.any?
              entity_keys.concat(request_ids.map { |id| "#{REQUEST_TRACE_KEY}:#{id}" }) if request_ids.any?
              
              # Delete all entity keys in one operation
              if entity_keys.any?
                keys_cleared += @redis.del(*entity_keys)
              end
              
              # Remove from size hashes
              @redis.hdel("#{WORKER_TRACE_KEY}:sizes", *worker_ids) if worker_ids.any?
              @redis.hdel("#{REQUEST_TRACE_KEY}:sizes", *request_ids) if request_ids.any?
            end
            
            # Remove test case from index and delete its key
            @redis.srem(TEST_CASE_INDEX_KEY, test_case_id)
            keys_cleared += @redis.del(test_case_key)
          end
        end
        
        keys_cleared
      end
      
      # Helper method to scan Redis for keys matching a pattern
      # @param pattern [String] Key pattern to match
      # @return [Array<String>] Matching keys
      def scan_keys(pattern)
        keys = []
        cursor = "0"
        
        loop do
          cursor, result = @redis.scan(cursor, match: pattern, count: 1000)
          keys.concat(result) if result.any?
          break if cursor == "0"
        end
        
        keys
      end
      
      private

      # Helper method to construct method_fullname from method_ident_array
      def construct_method_fullname(method_ident_array)
        return nil if method_ident_array.length < 2
        
        class_component = method_ident_array[0]
        method_name_sym = method_ident_array[1]
        
        # Fast path: if the third element is a clean string, use it directly
        if method_ident_array.length >= 3 && 
           method_ident_array[2].is_a?(String) && 
           !method_ident_array[2].start_with?("#<")
          return method_ident_array[2]
        end
        
        # Get class name - prioritize methods that don't involve string parsing
        class_name_str = if class_component.is_a?(String)
                           class_component
                         elsif class_component.respond_to?(:name) && 
                               class_component.name.is_a?(String) && 
                               !class_component.name.empty?
                           class_component.name
                         elsif class_component.to_s.start_with?("#<Class:")
                           # Handle singleton class case with minimal string operations
                           class_str = class_component.to_s
                           start_idx = 8  # Length of "#<Class:"
                           end_idx = class_str.index('(') || class_str.index('>')
                           class_str[start_idx...end_idx] if end_idx
                         else
                           class_component.to_s
                         end
        
        # Simple method name conversion
        method_name_str = method_name_sym.to_s
        
        # Efficient separator determination
        separator = if class_component.is_a?(Module) && !class_component.is_a?(Class)
                      "."  # Module methods
                    elsif class_component.to_s.start_with?("#<Class:")
                      "."  # Singleton class methods
                    else
                      "#"  # Instance methods (default)
                    end
        
        "#{class_name_str}#{separator}#{method_name_str}"
      end

      # Generates the Redis key for storing method coverage for a specific file.
      def method_coverage_key(relative_file, type, file_hash)
        prefix = key_prefix(type) # Uses the existing type-specific prefix
        [prefix, METHOD_STORAGE_KEY_SEGMENT, relative_file, file_hash].join(".")
      end

      # Generates the Redis key for the Set that stores all method_coverage_keys for a given type.
      def method_files_key(local_type = nil)
        "#{key_prefix(local_type)}.#{METHOD_STORAGE_KEY_SEGMENT}_files"
      end
      
      # Helper to get all method file keys for a given type
      def method_files_set(local_type = nil)
        @redis.smembers(method_files_key(local_type))
      end

      # Populates test_case_data_accumulator with structure:
      # { original_test_case_id => { request_id => { file_name => [line_numbers] } } }
      def add_test_case_map(test_case_data_accumulator, hash_from_redis)
        return if hash_from_redis.nil? || hash_from_redis.empty?

        file_name = hash_from_redis[FILE_KEY]
        test_cases_json = hash_from_redis['test_cases']

        return if file_name.nil? || test_cases_json.nil? || test_cases_json.empty?

        begin
          line_to_augmented_ids_map = JSON.parse(test_cases_json)
        rescue JSON::ParserError => e
          Coverband.configuration.logger.warn "Coverband: Malformed JSON in 'test_cases' for file #{file_name}: #{test_cases_json}. Error: #{e.message}"
          return
        end

        return unless line_to_augmented_ids_map.is_a?(Hash)

        separator = "::REQ::"

        line_to_augmented_ids_map.each do |line_number_str, augmented_ids_array|
          next unless augmented_ids_array.is_a?(Array)
          line_number = line_number_str.to_i

          augmented_ids_array.each do |augmented_id|
            next if augmented_id.nil? || augmented_id.empty?

            parts = augmented_id.to_s.split(separator, 2)
            original_test_case_id = parts[0]
            request_id = parts.length > 1 && !parts[1].empty? ? parts[1] : "UNKNOWN_REQUEST"

            test_case_data_accumulator[original_test_case_id] ||= {}
            test_case_data_accumulator[original_test_case_id][request_id] ||= {}
            test_case_data_accumulator[original_test_case_id][request_id][file_name] ||= []

            unless test_case_data_accumulator[original_test_case_id][request_id][file_name].include?(line_number)
              test_case_data_accumulator[original_test_case_id][request_id][file_name] << line_number
            end
          end
        end
      end

      # Populates the accumulator with method test case mappings.
      # Format: { original_test_case_id => { request_id => { file_name => [method_names] } } }
      def add_method_test_case_map(accumulator, hash_from_redis)
        return if hash_from_redis.nil? || hash_from_redis.empty?

        file_name = hash_from_redis[FILE_KEY] # 'file'
        test_cases_json = hash_from_redis['test_cases']

        return if file_name.nil? || test_cases_json.nil? || test_cases_json.empty?

        begin
          # Expected JSON: { "method_fullname1": ["{\"a\":\"1\",\"b\":\"GET\",...}", ...], ... }
          method_to_augmented_ids_map = JSON.parse(test_cases_json)
        rescue JSON::ParserError => e
          Coverband.configuration.logger.warn "Coverband: Malformed JSON in method 'test_cases' for file #{file_name}: #{test_cases_json}. Error: #{e.message}"
          return
        end

        return unless method_to_augmented_ids_map.is_a?(Hash)

        method_to_augmented_ids_map.each do |method_fullname, augmented_ids_array|
          next unless augmented_ids_array.is_a?(Array)
          augmented_ids_array.each do |augmented_id_json|
            next if augmented_id_json.nil? || augmented_id_json.empty?

            # Parse the JSON object that contains request details
            begin
              request_data = JSON.parse(augmented_id_json)
              # Extract key information from the parsed JSON
              test_case_id = request_data['a'] # Unique ID/request number
              http_method = request_data['b']  # HTTP method (GET, POST, etc.)
              request_path = request_data['c'] # Request path/URL
              status_code = request_data['d']  # HTTP status code
              
              # Create a more descriptive request_id that includes HTTP method and path
              request_id = "#{test_case_id}::#{http_method}::#{request_path}::#{status_code}"
              
              # Use test_case_id as the primary grouping key
              original_test_case_id = test_case_id

              # Initialize the structure if not already present
              accumulator[original_test_case_id] ||= {}
              accumulator[original_test_case_id][request_id] ||= {}
              
              # Group by file first, then collect methods for each file
              accumulator[original_test_case_id][request_id][file_name] ||= []
              
              # Add the method to the array for this file if not already present
              unless accumulator[original_test_case_id][request_id][file_name].include?(method_fullname)
                accumulator[original_test_case_id][request_id][file_name] << method_fullname
              end
            rescue JSON::ParserError => e
              # If we can't parse the JSON object, fall back to using the raw string
              Coverband.configuration.logger.warn "Coverband: Unable to parse request data JSON for method #{method_fullname}: #{augmented_id_json}. Error: #{e.message}"
              
              # Use the raw JSON string as both the original ID and request ID
              original_test_case_id = "raw_id"
              request_id = augmented_id_json.to_s[0..50] # Limit length for display purposes
              
              # Initialize and populate the accumulator as before
              accumulator[original_test_case_id] ||= {}
              accumulator[original_test_case_id][request_id] ||= {}
              accumulator[original_test_case_id][request_id][file_name] ||= []
              
              unless accumulator[original_test_case_id][request_id][file_name].include?(method_fullname)
                accumulator[original_test_case_id][request_id][file_name] << method_fullname
              end
            end
          end
        end
      end

      def add_coverage_for_file(data_from_redis, hash)
        return if data_from_redis.empty?

        file = data_from_redis[FILE_KEY]
        return unless file_hash(file) == data_from_redis[FILE_HASH]

        data = coverage_data_from_redis(data_from_redis)
        timedata = coverage_time_data_from_redis(data_from_redis)
        hash[file] = data_from_redis.slice(*META_DATA_KEYS).merge!("data" => data, "timedata" => timedata)
        hash[file][LAST_UPDATED_KEY] =
          (hash[file][LAST_UPDATED_KEY].nil? || hash[file][LAST_UPDATED_KEY] == "") ? nil : hash[file][LAST_UPDATED_KEY].to_i
        hash[file].merge!(LAST_UPDATED_KEY => hash[file][LAST_UPDATED_KEY],
          FIRST_UPDATED_KEY => hash[file][FIRST_UPDATED_KEY].to_i)
      end

      def coverage_data_from_redis(data_from_redis)
        max = data_from_redis[FILE_LENGTH_KEY].to_i - 1
        Array.new(max + 1) do |index|
          line_coverage = data_from_redis[index.to_s]
          line_coverage&.to_i
        end
      end

      def coverage_time_data_from_redis(data_from_redis)
        max = data_from_redis[FILE_LENGTH_KEY].to_i - 1
        Array.new(max + 1) do |index|
          unixtime = data_from_redis["#{index}_last_posted"]
          unixtime.nil? ? nil : Time.at(unixtime.to_i)
        end
      end

      def script_input(key:, file:, file_hash:, data:, report_time:, updated_time:, test_case_id: nil)
        coverage_data = data.each_with_index.each_with_object({}) do |(coverage, index), hash|
          hash[index] = coverage if coverage
        end
        meta = {
          first_updated_at: report_time,
          file: file,
          file_hash: file_hash,
          file_length: data.length,
          hash_key: key
        }
        meta[:last_updated_at] = updated_time if updated_time
        {
          hash_key: key,
          meta: meta,
          coverage: coverage_data
        }
      end

      def hash_incr_script
        @hash_incr_script ||= @redis.script(:load, lua_script_content)
      end

      # Loads and caches the SHA for the method coverage Lua script.
      def method_hash_incr_script_sha
        @method_hash_incr_script_sha ||= @redis.script(:load, method_lua_script_content)
      end

      def lua_script_content
        File.read(File.join(
          File.dirname(__FILE__), "../../../lua/lib/persist-coverage.lua"
        ))
      end

      def method_lua_script_content
        File.read(File.join(
          File.dirname(__FILE__), "../../../lua/lib/persist-method-coverage.lua"
        ))
      end

      def values_from_redis(local_type, files)
        return files if files.empty?

        @redis.mget(*files.map { |file| key(file, local_type) }).map do |value|
          value.nil? ? {} : JSON.parse(value)
        end
      end

      def relative_paths(files)
        files&.map! { |file| full_path_to_relative(file) }
      end

      def files_set(local_type = nil)
        @redis.smembers(files_key(local_type))
      end

      def files_key(local_type = nil)
        "#{key_prefix(local_type)}.files"
      end

      def key(file, local_type = nil, file_hash:)
        [key_prefix(local_type), file, file_hash].join(".")
      end

      def key_prefix(local_type = nil)
        local_type ||= type
        [@format_version, @redis_namespace, local_type].compact.join(".")
      end

      # Store method trace for a specific request ID
      # @param request_id [String] Unique identifier for the request (e.g. "GET::localhost:3000/api/v2/groups::200")
      # @param method_trace [Hash] Hash mapping file paths to arrays of method names
      # @param ttl [Integer] Time-to-live in seconds
      def save_request_method_trace(request_id, method_trace, ttl = TEST_CASE_EXPIRATION)
        return if request_id.nil? || method_trace.nil? || method_trace.empty?
        
        # Convert full paths to relative paths
        relative_method_trace = {}
        method_trace.each do |file_path, methods|
          next if methods.nil? || methods.empty?
          relative_path = @relative_file_converter.convert(file_path)
          relative_method_trace[relative_path] = methods
        end
        
        return if relative_method_trace.empty?
        
        # Generate request key
        request_key = "#{REQUEST_TRACE_KEY}:#{request_id}"
        
        # Store the method trace as JSON with TTL
        trace_json = relative_method_trace.to_json
        json_size_bytes = trace_json.bytesize
        
        @redis.set(request_key, trace_json, ex: ttl)
        @redis.hset("#{REQUEST_TRACE_KEY}:sizes", request_id, json_size_bytes.to_s)
      end
      
      # Store method trace for a specific worker class
      # @param worker_class [String] The worker class name
      # @param method_trace [Hash] Hash mapping file paths to arrays of method names
      # @param ttl [Integer] Time-to-live in seconds
      def save_worker_method_trace(worker_class, method_trace, ttl = TEST_CASE_EXPIRATION)
        return if worker_class.nil? || method_trace.nil? || method_trace.empty?
        
        worker_id = "worker::#{worker_class}"
        worker_key = "#{WORKER_TRACE_KEY}:#{worker_id}"
        
        # Convert and store same as requests
        relative_method_trace = {}
        method_trace.each do |file_path, methods|
          next if methods.nil? || methods.empty?
          relative_path = @relative_file_converter.convert(file_path)
          relative_method_trace[relative_path] = methods
        end
        
        return if relative_method_trace.empty?
        
        trace_json = relative_method_trace.to_json
        json_size_bytes = trace_json.bytesize
        
        @redis.set(worker_key, trace_json, ex: ttl)
        @redis.hset("#{WORKER_TRACE_KEY}:sizes", worker_id, json_size_bytes.to_s)
      end
      
      # Associate a request or worker with a test case
      # @param test_case_id [String] The test case identifier
      # @param entity_id [String] The request or worker ID
      def associate_with_test_case(test_case_id, entity_id)
        return if test_case_id.nil? || entity_id.nil?
        
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        
        # Add test case to index
        @redis.sadd(TEST_CASE_INDEX_KEY, test_case_id)
        
        # Add entity to test case's set
        @redis.sadd(test_case_key, entity_id)
        
        # Set TTL for test case set
        @redis.expire(test_case_key, TEST_CASE_EXPIRATION)
      end
      
      # Get full method trace for a test case by combining all associated request/worker traces
      # @param test_case_id [String] The test case identifier
      # @return [Hash] Combined method trace for all requests/workers in the test case
      def get_test_case_combined_method_trace(test_case_id)
        return nil if test_case_id.nil?
        
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        entity_ids = @redis.smembers(test_case_key)
        return nil if entity_ids.empty?
        
        combined_trace = {}
        
        entity_ids.each do |entity_id|
          trace = nil
          
          if entity_id.start_with?("worker::")
            worker_key = "#{WORKER_TRACE_KEY}:#{entity_id}"
            trace_json = @redis.get(worker_key)
            trace = JSON.parse(trace_json) if trace_json
          else
            request_key = "#{REQUEST_TRACE_KEY}:#{entity_id}"
            trace_json = @redis.get(request_key)
            trace = JSON.parse(trace_json) if trace_json
          end
          
          next unless trace
          
          # Merge this trace into the combined trace
          trace.each do |file, methods|
            combined_trace[file] ||= []
            methods.each do |method|
              combined_trace[file] << method unless combined_trace[file].include?(method)
            end
          end
        end
        
        combined_trace
      end
      
      # List all test case IDs
      # @return [Array<String>] Array of test case IDs
      def list_test_case_ids
        @redis.smembers(TEST_CASE_INDEX_KEY)
      end
      
      # Get all entity IDs (requests/workers) associated with a test case
      # @param test_case_id [String] The test case identifier
      # @return [Array<String>] Array of entity IDs
      def get_test_case_entities(test_case_id)
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        @redis.smembers(test_case_key)
      end
      
      # Delete all data for a test case
      # @param test_case_id [String] The test case identifier
      # @param delete_entities [Boolean] Whether to also delete the associated request/worker data
      def delete_test_case(test_case_id, delete_entities = false)
        return if test_case_id.nil?
        
        test_case_key = "#{TEST_CASE_MAP_KEY}:#{test_case_id}"
        
        if delete_entities
          entity_ids = @redis.smembers(test_case_key)
          entity_ids.each do |entity_id|
            if entity_id.start_with?("worker::")
              @redis.del("#{WORKER_TRACE_KEY}:#{entity_id}")
              @redis.hdel("#{WORKER_TRACE_KEY}:sizes", entity_id)
            else
              @redis.del("#{REQUEST_TRACE_KEY}:#{entity_id}")
              @redis.hdel("#{REQUEST_TRACE_KEY}:sizes", entity_id)
            end
          end
        end
        
        @redis.del(test_case_key)
        @redis.srem(TEST_CASE_INDEX_KEY, test_case_id)
      end
    end
  end
end
