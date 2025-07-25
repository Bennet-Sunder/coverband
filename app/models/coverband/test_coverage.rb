# frozen_string_literal: true

require 'active_record'

module Coverband
  class TestCoverage < ActiveRecord::Base
    self.table_name = 'coverband_test_coverage'

    belongs_to :request, class_name: 'Coverband::Request'
    belongs_to :coverage_method, class_name: 'Coverband::CoverageMethod'

    validates :request_id, presence: true
    validates :method_id, presence: true
    validates :method_id, uniqueness: { scope: :request_id }

    def self.bulk_insert_ignore_duplicates(coverages)
      return [] if coverages.empty?

      values = coverages.map { |c| 
        "(#{connection.quote(c[:request_id])}, #{connection.quote(c[:method_id])}, UTC_TIMESTAMP(6), UTC_TIMESTAMP(6))"
      }.join(",")

      sql = <<-SQL
        INSERT IGNORE INTO #{table_name} (request_id, method_id, created_at, updated_at)
        VALUES #{values};
      SQL
      
      connection.execute(sql)
      
      # Return the inserted/existing records
      where(request_id: coverages.map { |c| c[:request_id] })
        .where(method_id: coverages.map { |c| c[:method_id] })
        .pluck(:id)
        .map { |id| {'id' => id} }
    end
  end
end 