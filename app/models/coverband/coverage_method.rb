# frozen_string_literal: true

require 'active_record'

module Coverband
  class CoverageMethod < ActiveRecord::Base
    self.table_name = 'coverband_methods'

    has_many :test_coverages, class_name: 'Coverband::TestCoverage', foreign_key: 'method_id', dependent: :destroy
    has_many :requests, through: :test_coverages, class_name: 'Coverband::Request'

    validates :file_path, presence: true
    validates :method_name, presence: true
    validates :full_method_name, presence: true, uniqueness: { scope: :file_path }

  end
end 