# frozen_string_literal: true

require 'active_record'

module Coverband
  class TestCase < ActiveRecord::Base
    self.table_name = 'coverband_test_cases'

    has_many :requests, class_name: 'Coverband::Request', dependent: :destroy
    has_many :test_coverages, through: :requests, class_name: 'Coverband::TestCoverage'
    
    accepts_nested_attributes_for :requests
    
    validates :test_case_id, presence: true, uniqueness: true

    def self.bulk_insert_ignore_duplicates(test_cases)
      return [] if test_cases.empty?

      # First try to find existing records
      existing = where(test_case_id: test_cases.map { |tc| tc[:test_case_id] })
      return existing.map { |tc| {'id' => tc.id, 'test_case_id' => tc.test_case_id} } if existing.any?

      # If no existing records, create new ones
      timestamp = Time.current
      values = test_cases.map { |tc| 
        "(#{connection.quote(tc[:test_case_id])}, #{connection.quote(timestamp)}, #{connection.quote(timestamp)})"
      }.join(",")

      sql = <<-SQL
        INSERT IGNORE INTO #{table_name} (test_case_id, created_at, updated_at)
        VALUES #{values};
      SQL
      
      connection.execute(sql)
      
      # Return the newly created records
      where(test_case_id: test_cases.map { |tc| tc[:test_case_id] })
        .pluck(:id, :test_case_id)
        .map { |id, test_case_id| {'id' => id, 'test_case_id' => test_case_id} }
    end
  end
end 