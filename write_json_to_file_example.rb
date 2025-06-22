# frozen_string_literal: true

require 'json'

# 1. Define your Ruby object (typically a Hash or Array)
my_ruby_object = {
  project: "Coverband",
  timestamp: Time.now.to_s,
  status: "example",
  data: {
    message: "This is an example JSON object being written to a file.",
    items: ["item1", 2, {sub_item: "value"}],
    author_details: {
      name: "GitHub Copilot",
      task: "Write JSON to file"
    }
  }
}

# 2. Convert the Ruby object to a JSON string
# For a human-readable (pretty-printed) JSON string:
json_string = JSON.pretty_generate(my_ruby_object)

# For a compact JSON string, you would use:
# json_string = my_ruby_object.to_json

# 3. Specify the desired file path within your repository
# This example will save it in the 'tmp' directory.
# It assumes the script is run from the root of the Coverband project.
output_directory = File.join(File.dirname(__FILE__), 'tmp')
Dir.mkdir(output_directory) unless Dir.exist?(output_directory)
file_path = File.join(output_directory, 'example_output.json')

# 4. Write the JSON string to the file
begin
  File.open(file_path, "w") do |file|
    file.write(json_string)
  end
  puts "Successfully wrote JSON object to: #{file_path}"
rescue StandardError => e
  puts "Error writing JSON to file at #{file_path}: #{e.message}"
end

# To run this script:
# Navigate to your repository's root directory (/Users/bsunder/coverband)
# in the terminal and execute:
# ruby write_json_to_file_example.rb

file_name = '/Users/bsunder/coverband/first_request.json'
coverage = Coverband.configuration.store.extract_test_case_method_coverage[:coverage_data]
json_string = JSON.pretty_generate(coverage)
File.open(file_name, "w") do |file|
    file.write(json_string)
end
