# frozen_string_literal: true

require 'active_record'

module Coverband
  class TestCase < ActiveRecord::Base
    self.table_name = 'coverband_test_cases'
    self.primary_key = 'test_case_id'  # Use natural primary key

    has_many :requests, class_name: 'Coverband::Request', foreign_key: 'test_case_id', dependent: :destroy
    has_many :test_coverages, through: :requests, class_name: 'Coverband::TestCoverage'
  end
end 


