# frozen_string_literal: true

require 'json'
require 'optparse'

# Reads a JSON file and extracts the key for a given test case, then writes it to a separate file.
def extract_key_for_test_case(json_filepath, test_case_id, output_filepath)
  begin
    file_content = File.read(json_filepath)
    json_data = JSON.parse(file_content)
  rescue Errno::ENOENT
    puts "Error: JSON file '#{json_filepath}' not found."
    return
  rescue JSON::ParserError
    puts "Error: Could not decode JSON from '#{json_filepath}'."
    return
  end

  unless json_data.is_a?(Hash)
    puts "Error: The root of the JSON file is not a hash."
    return
  end
  key_data = json_data['coverage_data'][test_case_id.to_s]

  if key_data.nil?
    puts "Error: Test case ID '#{test_case_id}' not found in the JSON file."
    return
  end

  File.open(output_filepath, 'w') do |file|
    file.write(JSON.pretty_generate(key_data))
  end

  puts "Key data for test case '#{test_case_id}' has been written to '#{output_filepath}'."
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 1
    puts "Usage: extract_test_case_key.rb TEST_CASE_ID"
    exit 1
  end

  test_case_id = ARGV[0]
  json_filepath = '/Users/bsunder/Downloads/impact_tracer_map_all_cases_2.json'
  output_filepath = "/Users/bsunder/coverband/#{test_case_id}.json"

  extract_key_for_test_case(json_filepath, test_case_id, output_filepath)
end