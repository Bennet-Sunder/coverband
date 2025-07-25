# frozen_string_literal: true

class CreateCoverbandNormalizedSchema < ActiveRecord::Migration[6.1]
  shard :none
  def change
    
    # Test Cases table - core test case information
    create_table :coverband_test_cases, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :test_case_id, null: false, limit: 255
      t.json :metadata  # Any test-level metadata if needed
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Unique index to prevent duplicate test cases
      t.index :test_case_id, unique: true
      t.index :created_at
    end

    # Requests table - each test case can have multiple requests
    create_table :coverband_requests, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.references :test_case, null: false, foreign_key: { to_table: :coverband_test_cases }
      t.json :request_details  # Contains action_url, action_type, response_code, etc.
      t.string :request_signature, limit: 500  # For quick lookups: "POST:/api/v2/agents:201"
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Unique composite index to prevent duplicate requests for the same test case
      t.index [:test_case_id, :request_signature], unique: true
      t.index :request_signature
    end

    # Files table - unique file paths
    create_table :coverband_files, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.string :file_path, null: false, limit: 500
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Indexes for performance
      t.index :file_path, unique: true
    end

    # Methods table - method definitions linked to files
    create_table :coverband_methods, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.references :file, null: false, foreign_key: { to_table: :coverband_files }
      t.string :class_name, limit: 255
      t.string :method_name, null: false, limit: 255
      t.string :full_method_name, null: false, limit: 500
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Indexes for performance
      t.index :full_method_name, unique: true
      t.index [:file_id, :method_name]
      t.index [:class_name, :method_name]
    end

    # Test Coverage junction table - links requests to methods they cover
    create_table :coverband_test_coverage, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.references :request, null: false, foreign_key: { to_table: :coverband_requests }
      t.references :method, null: false, foreign_key: { to_table: :coverband_methods }
      t.timestamp :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Prevent duplicate coverage records for same request-method combination
      t.index [:request_id, :method_id], unique: true
    end
  end
end
