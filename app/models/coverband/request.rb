# frozen_string_literal: true

require 'active_record'
require 'json'

module Coverband
  class Request < ActiveRecord::Base
    self.table_name = 'coverband_requests'
    self.primary_key = 'request_id'  # Use natural primary key

    belongs_to :test_case, class_name: 'Coverband::TestCase', foreign_key: 'test_case_id', primary_key: 'test_case_id'
    has_many :test_coverages, class_name: 'Coverband::TestCoverage', foreign_key: 'request_id', dependent: :destroy
    has_many :coverage_methods, through: :test_coverages, class_name: 'Coverband::CoverageMethod'

    accepts_nested_attributes_for :test_coverages
    
    validates :request_id, presence: true
    validates :test_case_id, presence: true
    validates :request_details, presence: true
  end
end 