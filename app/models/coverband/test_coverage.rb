# frozen_string_literal: true

require 'active_record'

module Coverband
  class TestCoverage < ActiveRecord::Base
    self.table_name = 'coverband_test_coverage'

    belongs_to :request, class_name: 'Coverband::Request', foreign_key: 'request_id', primary_key: 'request_id'
    belongs_to :coverage_method, class_name: 'Coverband::CoverageMethod', foreign_key: 'method_id'

    validates :request_id, presence: true
    validates :method_id, presence: true
    validates :method_id, uniqueness: { scope: :request_id }
  end
end 