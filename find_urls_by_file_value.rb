# frozen_string_literal: true

require 'json'
require 'set'
require 'byebug'

# Reads a JSON file and returns a hash mapping PR numbers to impacted test cases and request URLs
# Expected JSON structure for coverage_data:
# {
#   "test-case-id": {
#     "request-url": {
#       "file-name": ["method1", ...]
#     }
#   }
# }
def get_impacted_test_cases_and_request_urls(json_filepath, pr_method_changes_filepath)
  begin
    coverage_file_content = File.read(json_filepath)
    coverage_data = JSON.parse(coverage_file_content)
  rescue Errno::ENOENT
    puts "Error: JSON file '#{json_filepath}' not found."
    return {}
  rescue JSON::ParserError
    puts "Error: Could not decode JSON from '#{json_filepath}'."
    return {}
  end

  begin
    pr_method_changes_content = File.read(pr_method_changes_filepath)
    pr_method_changes = JSON.parse(pr_method_changes_content)
  rescue Errno::ENOENT
    puts "Error: JSON file '#{pr_method_changes_filepath}' not found."
    return {}
  rescue JSON::ParserError
    puts "Error: Could not decode JSON from '#{pr_method_changes_filepath}'."
    return {}
  end

  unless coverage_data.is_a?(Hash)
    puts "Error: The root of the coverage JSON file is not a hash (expected test-case-ids as top-level keys)."
    return {}
  end

  coverage_data = coverage_data['coverage_data']
  impacted_data = {}

  pr_method_changes.each do |pr_number, files|
    impacted_data[pr_number] = { test_cases: {}, test_case_count: 0 }

    files.each_key do |filename_to_find_as_key|
      normalized_input_filename = filename_to_find_as_key.start_with?("./") ? filename_to_find_as_key[2..-1] : filename_to_find_as_key
      normalized_input_filename = filename_to_find_as_key if normalized_input_filename.nil? && filename_to_find_as_key == "./"

      coverage_data.each do |test_case_id, test_case_data|
        next unless test_case_data.is_a?(Hash)

        test_case_data.each do |request_url, request_files_data|
          next unless request_files_data.is_a?(Hash)

          request_files_data.each_key do |json_filename_key|
            normalized_json_filename = json_filename_key.start_with?("./") ? json_filename_key[2..-1] : json_filename_key
            normalized_json_filename = json_filename_key if normalized_json_filename.nil? && json_filename_key == "./"

            if normalized_json_filename == normalized_input_filename
              pr_method_names = files[normalized_input_filename].values.flatten.uniq
              method_names = request_files_data[normalized_input_filename]
              filtered_names = pr_method_names.select do |pr_method_name|
                method_names.any? { |method_name| method_name.include?(pr_method_name) }
              end
              next if filtered_names.empty?
              puts "Found matching methods for PR #{pr_number} in file '#{normalized_input_filename}' for test case '#{test_case_id}' with request URL '#{request_url}': #{filtered_names.join(', ')}"
              impacted_data[pr_number][:test_cases][test_case_id] ||= []
              impacted_data[pr_number][:test_cases][test_case_id] << request_url unless impacted_data[pr_number][:test_cases][test_case_id].include?(request_url)
              break # Found for this request_url, no need to check other files under it
            end
          end
        end
      end
    end
  end
  impacted_data.each do |pr_number, data|
    data[:test_case_count] = data[:test_cases].keys.count
    data[:test_case_list] = data[:test_cases].keys.uniq.sort
  end
  impacted_data
end

if __FILE__ == $PROGRAM_NAME
  hardcoded_coverage_json_filepath = '/Users/bsunder/Downloads/impact_tracer_map_all_cases_2.json'
  hardcoded_pr_method_changes_filepath = '/Users/bsunder/coverband/pr_method_changes.json'

  impacted_data = get_impacted_test_cases_and_request_urls(hardcoded_coverage_json_filepath, hardcoded_pr_method_changes_filepath)

  output_filepath = '/Users/bsunder/coverband/impacted_test_cases_and_request_urls.json'
  File.open(output_filepath, 'w') do |file|
    file.write(JSON.pretty_generate(impacted_data))
  end

  puts "Impacted test cases and request URLs have been written to '#{output_filepath}'."
end