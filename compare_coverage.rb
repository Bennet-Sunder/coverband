#!/usr/bin/env ruby
# frozen_string_literal: true

# Install required gems if they're missing
begin
  require 'json'
  require 'optparse'
  require 'set'
  require 'colorize'
rescue LoadError => e
  if e.message.include?('colorize')
    puts "Installing missing colorize gem..."
    system('gem install colorize')
    Gem.clear_paths
    require 'colorize'
  else
    puts "Error: #{e.message}"
    puts "Please install required gems: gem install json optparse colorize"
    exit 1
  end
end

# Parse command line options
options = {
  detail_level: 1,  # 0=basic, 1=detailed, 2=full
  output_file: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: compare_coverage.rb [options] file1.json file2.json"
  
  opts.on("-d", "--detail LEVEL", Integer, "Detail level (0=basic, 1=detailed, 2=full)") do |level|
    options[:detail_level] = level
  end
  
  opts.on("-o", "--output FILE", "Output file (default: stdout)") do |file|
    options[:output_file] = file
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end

parser.parse!

if ARGV.length != 2
  puts "Error: Please provide exactly two JSON files to compare"
  puts parser
  exit 1
end

file1_path = ARGV[0]
file2_path = ARGV[1]

# Check if files exist
unless File.exist?(file1_path)
  puts "Error: File '#{file1_path}' not found"
  exit 1
end

unless File.exist?(file2_path)
  puts "Error: File '#{file2_path}' not found"
  exit 1
end

# Read and parse JSON files
begin
  file1_data = JSON.parse(File.read(file1_path))
  file2_data = JSON.parse(File.read(file2_path))
rescue JSON::ParserError => e
  puts "Error parsing JSON: #{e.message}"
  exit 1
end

# Normalize and compare the data structure
def normalize_data(data)
  normalized = {}
  
  data.each do |test_id, test_data|
    normalized[test_id] = {}
    
    # Process each request
    test_data.each do |request_id, files_data|
      normalized[test_id][request_id] = {}
      
      # Process each file
      files_data.each do |file_path, methods|
        # Sort methods to ensure consistent comparison
        normalized[test_id][request_id][file_path] = methods.sort
      end
    end
  end
  
  normalized
end

file1_normalized = normalize_data(file1_data)
file2_normalized = normalize_data(file2_data)

# Compare test case IDs
test_ids1 = file1_normalized.keys
test_ids2 = file2_normalized.keys

common_test_ids = test_ids1 & test_ids2
unique_test_ids1 = test_ids1 - test_ids2
unique_test_ids2 = test_ids2 - test_ids1

# Create report
report = []
report << "Coverage Comparison Report"
report << "=========================="
report << "File 1: #{file1_path}"
report << "File 2: #{file2_path}"
report << ""
report << "Summary:"
report << "--------"
report << "Test IDs in File 1: #{test_ids1.count}"
report << "Test IDs in File 2: #{test_ids2.count}"
report << "Common Test IDs: #{common_test_ids.count}"
report << "Unique to File 1: #{unique_test_ids1.count}"
report << "Unique to File 2: #{unique_test_ids2.count}"
report << ""

if options[:detail_level] >= 1
  # Analyze each common test ID
  common_test_ids.each do |test_id|
    # Get request IDs for each test
    requests1 = file1_normalized[test_id].keys
    requests2 = file2_normalized[test_id].keys
    
    common_requests = requests1 & requests2
    unique_requests1 = requests1 - requests2
    unique_requests2 = requests2 - requests1
    
    report << "Test ID: #{test_id}".light_green
    report << "  Requests in File 1: #{requests1.count}"
    report << "  Requests in File 2: #{requests2.count}"
    report << "  Common Requests: #{common_requests.count}"
    
    if unique_requests1.any?
      report << "  Requests unique to File 1: #{unique_requests1.count}"
      if options[:detail_level] >= 2
        unique_requests1.each { |req| report << "    - #{req}" }
      end
    end
    
    if unique_requests2.any?
      report << "  Requests unique to File 2: #{unique_requests2.count}"
      if options[:detail_level] >= 2
        unique_requests2.each { |req| report << "    - #{req}" }
      end
    end
    
    # Analyze each common request
    common_requests.each do |request_id|
      files1 = file1_normalized[test_id][request_id].keys
      files2 = file2_normalized[test_id][request_id].keys
      
      common_files = files1 & files2
      unique_files1 = files1 - files2
      unique_files2 = files2 - files1
      
      method_diffs = {}
      
      # Compare methods for common files
      common_files.each do |file|
        methods1 = file1_normalized[test_id][request_id][file]
        methods2 = file2_normalized[test_id][request_id][file]
        
        if methods1 != methods2
          unique_methods1 = methods1 - methods2
          unique_methods2 = methods2 - methods1
          method_diffs[file] = {
            added: unique_methods2,
            removed: unique_methods1
          }
        end
      end
      
      # Only show request details if there are differences
      if unique_files1.any? || unique_files2.any? || method_diffs.any?
        report << "  Request: #{request_id}".yellow
        
        if unique_files1.any?
          report << "    Files unique to File 1: #{unique_files1.count}"
          if options[:detail_level] >= 2
            unique_files1.each { |file| report << "      - #{file}" }
          end
        end
        
        if unique_files2.any?
          report << "    Files unique to File 2: #{unique_files2.count}"
          if options[:detail_level] >= 2
            unique_files2.each { |file| report << "      - #{file}" }
          end
        end
        
        if method_diffs.any?
          report << "    Files with method differences: #{method_diffs.count}"
          
          if options[:detail_level] >= 2
            method_diffs.each do |file, diff|
              report << "      File: #{file}"
              
              if diff[:removed].any?
                report << "        Methods removed (in File 1 but not in File 2): #{diff[:removed].count}"
                diff[:removed].each { |method| report << "          - #{method}".red }
              end
              
              if diff[:added].any?
                report << "        Methods added (in File 2 but not in File 1): #{diff[:added].count}"
                diff[:added].each { |method| report << "          - #{method}".green }
              end
            end
          end
        end
      end
    end
    
    report << ""
  end
end

# Handle unique test IDs with higher detail levels
if options[:detail_level] >= 2
  if unique_test_ids1.any?
    report << "Test IDs unique to File 1:".light_blue
    unique_test_ids1.each do |test_id|
      report << "  #{test_id}"
      requests = file1_normalized[test_id].keys
      report << "  Request count: #{requests.count}"
      
      # Count total files and methods
      file_count = 0
      method_count = 0
      requests.each do |req|
        file_count += file1_normalized[test_id][req].keys.count
        file1_normalized[test_id][req].each do |_, methods|
          method_count += methods.count
        end
      end
      
      report << "  Total files: #{file_count}"
      report << "  Total methods: #{method_count}"
      report << ""
    end
  end
  
  if unique_test_ids2.any?
    report << "Test IDs unique to File 2:".light_blue
    unique_test_ids2.each do |test_id|
      report << "  #{test_id}"
      requests = file2_normalized[test_id].keys
      report << "  Request count: #{requests.count}"
      
      # Count total files and methods
      file_count = 0
      method_count = 0
      requests.each do |req|
        file_count += file2_normalized[test_id][req].keys.count
        file2_normalized[test_id][req].each do |_, methods|
          method_count += methods.count
        end
      end
      
      report << "  Total files: #{file_count}"
      report << "  Total methods: #{method_count}"
      report << ""
    end
  end
end

# Calculate statistics
total_common_files = 0
total_common_methods = 0
total_unique_files1 = 0
total_unique_files2 = 0
total_unique_methods1 = 0
total_unique_methods2 = 0

common_test_ids.each do |test_id|
  common_requests = file1_normalized[test_id].keys & file2_normalized[test_id].keys
  
  common_requests.each do |req|
    common_files = file1_normalized[test_id][req].keys & file2_normalized[test_id][req].keys
    total_common_files += common_files.count
    
    # Unique files
    total_unique_files1 += (file1_normalized[test_id][req].keys - file2_normalized[test_id][req].keys).count
    total_unique_files2 += (file2_normalized[test_id][req].keys - file1_normalized[test_id][req].keys).count
    
    # Methods
    common_files.each do |file|
      methods1 = file1_normalized[test_id][req][file]
      methods2 = file2_normalized[test_id][req][file]
      
      common_methods = methods1 & methods2
      total_common_methods += common_methods.count
      
      total_unique_methods1 += (methods1 - methods2).count
      total_unique_methods2 += (methods2 - methods1).count
    end
  end
end

report << "Statistics:".light_magenta
report << "------------"
report << "Common files: #{total_common_files}"
report << "Common methods: #{total_common_methods}"
report << "Files unique to File 1: #{total_unique_files1}"
report << "Files unique to File 2: #{total_unique_files2}"
report << "Methods unique to File 1: #{total_unique_methods1}"
report << "Methods unique to File 2: #{total_unique_methods2}"

# Output the report
if options[:output_file]
  File.write(options[:output_file], report.join("\n"))
  puts "Report written to #{options[:output_file]}"
else
  puts report.join("\n")
end