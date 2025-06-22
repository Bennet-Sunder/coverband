require 'json'

file_path = '/Users/bsunder/coverband/test/benchmarks/method_coverage.json'

begin
  file_content = File.read(file_path)
  data = JSON.parse(file_content)
  key_count = data.keys.length
  file_size_bytes = File.size(file_path)
  file_size_mb = file_size_bytes / (1024.0 * 1024.0)
  puts "The file #{file_path} has #{key_count} top-level keys and its size is %.2f MB." % file_size_mb
rescue JSON::ParserError => e
  puts "Error parsing JSON: #{e.message}"
rescue Errno::ENOENT
  puts "Error: File not found at #{file_path}"
rescue => e
  puts "An unexpected error occurred: #{e.message}"
end
