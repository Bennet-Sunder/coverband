# frozen_string_literal: true

class CreateCoverbandNormalizedSchema < ActiveRecord::Migration[6.1]
  shard :all
  def change
    # Test Cases table - uses natural primary key
    create_table :coverband_test_cases, id: false, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :test_case_id, null: false, limit: 255, primary_key: true
      t.json :metadata  # Any test-level metadata if needed
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Indexes for performance
      t.index :created_at
    end

    # Requests table - uses natural primary key from JID/UUID
    create_table :coverband_requests, id: false, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :request_id, null: false, limit: 255, primary_key: true  # JID or UUID from request_details
      t.string :test_case_id, null: false, limit: 255  # FK to coverband_test_cases
      t.json :request_details  # Contains action_url, action_type, response_code, etc.
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Foreign key constraints
      t.foreign_key :coverband_test_cases, column: :test_case_id, primary_key: :test_case_id

      # Indexes for performance
      t.index :test_case_id
      t.index :created_at
    end

    # Methods table - denormalized with file_path, no separate files table
    create_table :coverband_methods, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :file_path, null: false, limit: 400          # Denormalized from files table  
      t.string :class_name, limit: 255                      # Extracted from full_method_name
      t.string :method_name, null: false, limit: 255        # Extracted from full_method_name
      t.string :full_method_name, null: false, limit: 300   # "ClassName#method_name" format
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Indexes for performance and uniqueness
      t.index [:file_path, :full_method_name], unique: true  # True uniqueness: same method can exist in different files
      t.index :full_method_name                              # For fast method name lookups
      t.index [:file_path, :method_name]
      t.index [:class_name, :method_name]
      t.index :file_path
    end

    # Test Coverage junction table - links requests to methods they cover
    create_table :coverband_test_coverage, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :request_id, null: false, limit: 255    # FK to coverband_requests.request_id
      t.bigint :method_id, null: false                  # FK to coverband_methods.id (still auto-increment)
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Foreign key constraints
      t.foreign_key :coverband_requests, column: :request_id, primary_key: :request_id
      t.foreign_key :coverband_methods, column: :method_id, primary_key: :id

      # Prevent duplicate coverage records for same request-method combination
      t.index [:request_id, :method_id], unique: true
      t.index :method_id
    end
  end
end
