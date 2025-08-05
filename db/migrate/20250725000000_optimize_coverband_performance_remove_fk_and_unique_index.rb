# frozen_string_literal: true

class OptimizeCoverbandPerformanceRemoveFkAndUniqueIndex < ActiveRecord::Migration[6.1]
  shard :all
  
  def up
    remove_foreign_key :coverband_test_coverage, column: :request_id
    remove_foreign_key :coverband_test_coverage, column: :method_id
    
    remove_index :coverband_test_coverage, [:request_id, :method_id]
  end
  
  def down
    add_index :coverband_test_coverage, [:request_id, :method_id], unique: true
    
    add_foreign_key :coverband_test_coverage, :coverband_requests, 
                    column: :request_id, primary_key: :request_id
    
    add_foreign_key :coverband_test_coverage, :coverband_methods, 
                    column: :method_id, primary_key: :id
  end
end 