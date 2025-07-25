# frozen_string_literal: true

require 'active_record'

module Coverband
  class CoverageMethod < ActiveRecord::Base
    self.table_name = 'coverband_methods'

    belongs_to :coverage_file, class_name: 'Coverband::CoverageFile'
    has_many :test_coverages, class_name: 'Coverband::TestCoverage', dependent: :destroy
    has_many :requests, through: :test_coverages, class_name: 'Coverband::Request'

    validates :file_id, presence: true
    validates :full_method_name, presence: true
    validates :full_method_name, uniqueness: { scope: :file_id }

    def self.find_or_bulk_create(methods)
      return {} if methods.empty?
      
      # First try to find existing records
      existing_methods = where(
        file_id: methods.map { |m| m[:file_id] },
        full_method_name: methods.map { |m| m[:full_method_name] }
      ).pluck(:full_method_name, :id).to_h
      
      # Identify new methods
      new_methods = methods.reject { |m| existing_methods[m[:full_method_name]] }
      
      # Create new records if needed
      if new_methods.any?
        values = new_methods.map { |m| 
          class_name = connection.quote(m[:class_name])
          method_name = connection.quote(m[:method_name])
          full_name = connection.quote(m[:full_method_name])
          "(#{m[:file_id]}, #{class_name}, #{method_name}, #{full_name})"
        }.join(",")

        sql = <<-SQL
          INSERT IGNORE INTO #{table_name} 
          (file_id, class_name, method_name, full_method_name)
          VALUES #{values};
        SQL
        
        connection.execute(sql)
        
        # Get the newly created records
        new_records = where(
          file_id: new_methods.map { |m| m[:file_id] },
          full_method_name: new_methods.map { |m| m[:full_method_name] }
        ).pluck(:full_method_name, :id)
        
        # Add new records to the hash
        new_records.each do |full_method_name, id|
          existing_methods[full_method_name] = id
        end
      end
      
      existing_methods
    end
  end
end 