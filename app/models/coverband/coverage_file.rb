# frozen_string_literal: true

require 'active_record'

module Coverband
  class CoverageFile < ActiveRecord::Base
    self.table_name = 'coverband_files'

    has_many :coverage_methods, class_name: 'Coverband::CoverageMethod', dependent: :destroy

    validates :file_path, presence: true, uniqueness: true

    def self.find_or_bulk_create(file_paths)
      # First try to find existing records
      existing_files = where(file_path: file_paths).pluck(:file_path, :id).to_h
      
      # Identify new file paths
      new_file_paths = file_paths - existing_files.keys
      
      # Create new records if needed
      if new_file_paths.any?
        values = new_file_paths.map { |path| 
          "(#{connection.quote(path)})"
        }.join(",")

        sql = <<-SQL
          INSERT IGNORE INTO #{table_name} (file_path)
          VALUES #{values};
        SQL
        
        connection.execute(sql)
        
        # Get the newly created records
        new_records = where(file_path: new_file_paths).pluck(:file_path, :id)
        
        # Add new records to the hash
        new_records.each do |file_path, id|
          existing_files[file_path] = id
        end
      end
      
      existing_files
    end
  end
end 