#!/usr/bin/env ruby
# Script to upload a large JSON object to S3
require File.expand_path('../config/environment', __FILE__)
require 'tempfile'

class LargeJsonS3Uploader
  def self.upload(json_object, s3_key, bucket_name = S3_CONFIG[:bucket])
    if json_object.nil? || s3_key.nil?
      puts "Error: Both JSON object and S3 key are required"
      return false
    end
    
    # For very large objects, use a tempfile to avoid memory issues
    begin
      puts "Creating temporary file..."
      tempfile = Tempfile.new(['large_json', '.json'])
      
      # Write the JSON object to the tempfile
      puts "Writing JSON to temporary file..."
      if json_object.is_a?(String)
        tempfile.write(json_object)
      else
        tempfile.write(JSON.generate(json_object))
      end
      tempfile.flush
      tempfile.rewind
      
      # Use the existing CloudAdapter::Storage for the upload
      puts "Uploading to S3 bucket: #{bucket_name}, key: #{s3_key}..."
      
      # Use the actual file data instead of trying to access internal S3 client
      file_content = File.open(tempfile.path, 'rb')
      
      CloudAdapter::Storage.store(
        s3_key,
        file_content,
        bucket_name,
        {
          content_type: 'application/json',
          server_side_encryption: 'AES256'
        }
      )
      
      puts "Upload successful!"
      puts "File URL: #{CloudAdapter::Storage.url_for(s3_key, bucket_name, expires_in: 1.hour.to_i)}"
      true
    rescue => e
      puts "Error uploading to S3: #{e.message}"
      puts e.backtrace.join("\n")
      false
    ensure
      # Clean up the tempfile
      tempfile.close
      tempfile.unlink if tempfile.respond_to?(:unlink)
    end
  end
end

# # Example usage:
# # json_object = { "key" => "value", ... } # or a JSON string

# all_cases = Coverband.configuration.store.extract_test_case_method_coverage

# LargeJsonS3Uploader.upload(all_cases, "impact_tracer_map_all_cases_2.json")
