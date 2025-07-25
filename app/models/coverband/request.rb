# frozen_string_literal: true

require 'active_record'
require 'json'

module Coverband
  class Request < ActiveRecord::Base
    self.table_name = 'coverband_requests'

    belongs_to :test_case, class_name: 'Coverband::TestCase'
    has_many :test_coverages, class_name: 'Coverband::TestCoverage', dependent: :destroy
    has_many :coverage_methods, through: :test_coverages, class_name: 'Coverband::CoverageMethod'

    accepts_nested_attributes_for :test_coverages
    
    validates :test_case_id, presence: true
    validates :request_details, uniqueness: { scope: :test_case_id }

    def self.bulk_insert_ignore_duplicates(requests)
      return [] if requests.empty?

      values = requests.map { |r| 
        details_json = connection.quote(normalize_json(r[:request_details]))
        "(#{connection.quote(r[:test_case_id])}, #{details_json})"
      }.join(",")

      sql = <<-SQL
        INSERT IGNORE INTO #{table_name} (test_case_id, request_details)
        VALUES #{values};
      SQL
      
      connection.execute(sql)
      
      # Return the inserted/existing records
      normalized_details = requests.map { |r| normalize_json(r[:request_details]) }
      where(test_case_id: requests.map { |r| r[:test_case_id] })
        .where("JSON_UNQUOTE(JSON_EXTRACT(request_details, '$')) IN (?)", normalized_details)
        .pluck(:id)
        .map { |id| {'id' => id} }
    end

    private

    def self.normalize_json(data)
      return data if data.is_a?(String)
      JSON.generate(data.as_json, sort_keys: true)
    end
  end
end 