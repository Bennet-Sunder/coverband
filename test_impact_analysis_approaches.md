# Test Impact Prediction System: Comprehensive Analysis & Approaches

## Current System Overview

Your system uses Coverband to capture method-level test coverage and stores it in MySQL with JSON columns. The workflow involves:

1. **Map Generation**: 20,000 test cases generate coverage data stored as large JSON payloads (~16KB each)
2. **PR Analysis**: Extract file/method changes from GitHub PRs using git diffs
3. **Test Prediction**: Query coverage data to find impacted test cases based on PR changes

## Challenge Analysis

### 1. **Performance Bottlenecks**

**Large JSON Payloads (Current Approach)**
```sql
-- Your current insert (16.8ms)
INSERT INTO test_coverage (test_case_id, request_details, file_paths, created_at, updated_at) 
VALUES (2307626, '{...}', '{large_json_with_methods}', NOW(), NOW())
```

**Problems:**
- JSON parsing overhead on every operation
- Cannot effectively index method names within JSON
- Full payload deserialization for simple queries
- Memory intensive batch operations
- Difficult partial updates

### 2. **Query Performance Issues**

Current queries likely require:
```sql
-- Inefficient: requires full JSON scan
SELECT * FROM test_coverage 
WHERE JSON_EXTRACT(file_paths, '$."lib/some_file.rb"') IS NOT NULL
```

### 3. **Write Scalability**
- 20,000 × 16KB = 320MB of JSON data per full run
- Index maintenance overhead
- Transaction contention during bulk inserts

## Approach 1: **Optimized JSON Schema (Quick Fix)**

### Schema Modifications
```sql
-- Add targeted indexes for common queries
CREATE INDEX idx_test_coverage_files ON test_coverage 
((CAST(file_paths AS JSON)));

-- Add generated columns for frequent file lookups
ALTER TABLE test_coverage 
ADD COLUMN files_array JSON GENERATED ALWAYS AS (JSON_KEYS(file_paths)) STORED;

CREATE INDEX idx_files_array ON test_coverage (
    (CAST(files_array AS CHAR(1000) ARRAY))
);
```

### Optimize Data Structure
```json
// Instead of verbose method names, use compressed format
{
  "f": {  // files
    "lib/msp/callback_registry.rb": ["m1", "m2", "m3"],  // method indexes
    "app/workers/base_worker.rb": ["m4", "m5"]
  },
  "m": {  // method lookup table
    "m1": "Msp::CallbackRegistry#_inject_conditions!",
    "m2": "Msp::CallbackRegistry#_modify_account_callbacks",
    // ...
  }
}
```

**Pros:**
- Minimal schema changes
- Immediate performance improvement
- Backwards compatible

**Cons:**
- Still limited by JSON performance
- Complex queries remain difficult
- Scaling issues persist

## Approach 2: **Hybrid Normalized Schema (Recommended)**

### New Schema Design

```sql
-- Core entities
CREATE TABLE test_cases (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    test_case_id VARCHAR(255) NOT NULL UNIQUE,
    request_details JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_test_case_id (test_case_id)
);

CREATE TABLE files (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    file_path VARCHAR(500) NOT NULL UNIQUE,
    file_hash VARCHAR(64),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_file_path (file_path)
);

CREATE TABLE methods (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    file_id BIGINT NOT NULL,
    class_name VARCHAR(255),
    method_name VARCHAR(255) NOT NULL,
    full_method_name VARCHAR(500) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (file_id) REFERENCES files(id),
    INDEX idx_full_method_name (full_method_name),
    INDEX idx_file_method (file_id, method_name),
    INDEX idx_class_method (class_name, method_name)
);

CREATE TABLE test_coverage (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    test_case_id BIGINT NOT NULL,
    method_id BIGINT NOT NULL,
    execution_count INT DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (test_case_id) REFERENCES test_cases(id),
    FOREIGN KEY (method_id) REFERENCES methods(id),
    UNIQUE KEY unique_test_method (test_case_id, method_id),
    INDEX idx_test_case (test_case_id),
    INDEX idx_method (method_id)
);
```

### Data Storage Optimization

**Before (Current):**
```sql
-- 16KB JSON per test case
INSERT INTO test_coverage VALUES (2307626, '{...16KB_JSON...}');
```

**After (Normalized):**
```sql
-- Multiple small, indexed records
INSERT INTO test_coverage (test_case_id, method_id, execution_count) VALUES
(1, 1001, 1), (1, 1002, 3), (1, 1003, 1);  -- ~50 bytes per record
```

### Query Performance Improvements

**Finding impacted tests:**
```sql
-- Fast indexed lookup instead of JSON scanning
SELECT DISTINCT tc.test_case_id 
FROM test_coverage coverage
JOIN methods m ON coverage.method_id = m.id
JOIN files f ON m.file_id = f.id
WHERE f.file_path IN ('lib/some_file.rb', 'app/models/user.rb')
  AND m.method_name IN ('save_user', 'validate_user');
```

**Pros:**
- Fast indexed queries
- Efficient writes with bulk inserts
- Scalable storage (no JSON parsing overhead)
- Flexible querying
- Clear data relationships

**Cons:**
- Schema migration required
- More complex application logic
- Multiple table joins

## Approach 3: **Time-Series Database (Advanced)**

### Using ClickHouse or TimescaleDB

```sql
-- ClickHouse optimized for analytical queries
CREATE TABLE test_coverage_events (
    timestamp DateTime64,
    test_case_id UInt64,
    file_path String,
    method_name String,
    class_name String,
    execution_count UInt32
) ENGINE = MergeTree()
ORDER BY (test_case_id, file_path, method_name, timestamp);
```

**Pros:**
- Exceptional query performance for analytics
- Excellent compression ratios
- Built for high-volume inserts

**Cons:**
- Additional infrastructure complexity
- Learning curve
- Eventual consistency considerations

## Implementation Strategy

### Phase 1: Quick Wins (1-2 weeks)
1. **Optimize Current JSON Schema**
   - Add strategic indexes
   - Implement data compression
   - Optimize batch writes

```ruby
# Improve batch writing
class MysqlJsonStore
  def batch_insert_optimized(items)
    compressed_items = items.map do |item|
      {
        test_case_id: item[:test_case_id],
        request_details: compress_json(item[:request_details]),
        file_paths: compress_methods_json(item[:file_paths])
      }
    end
    
    TestCoverage.insert_all(compressed_items)
  end
end
```

### Phase 2: Hybrid Migration (2-4 weeks)
1. **Create normalized tables alongside existing**
2. **Implement dual-write during transition**
3. **Migrate historical data in batches**
4. **Update query logic progressively**

### Phase 3: PR Analysis Consistency (1-2 weeks)
1. **Standardize method name format**
2. **Improve git diff parsing**
3. **Add validation pipeline**

## PR Analysis Consistency Solution

Your current challenge with matching PR-extracted methods to stored data:

### Standardize Method Name Format

```ruby
# lib/coverband/utils/method_name_standardizer.rb
class MethodNameStandardizer
  def self.standardize(class_name, method_name)
    # Convert various formats to consistent format
    simplified_class = simplify_class_name(class_name)
    "#{simplified_class}##{method_name}"
  end
  
  def self.simplify_class_name(class_name)
    # Convert "#<Class:Cmdb::CiLevel_0Field(id: integer...)>" 
    # to "Cmdb::CiLevel_0Field"
    class_name.gsub(/#<Class:([^(]+).*/, '\1')
  end
end
```

### Enhanced PR Analysis

```ruby
# Enhanced analyze_pr_changes.rb
def analyze_diff_with_context(diff_content, pr_number)
  file_changes = {}
  
  diff_content.each_line do |line|
    if line.match(/^\+.*def\s+([a-zA-Z_][\w.]*[!?=]?)/)
      method_name = $1
      # Use same standardization as coverage collection
      standardized_name = MethodNameStandardizer.standardize(current_class, method_name)
      file_changes[current_file][:added] << standardized_name
    end
  end
  
  file_changes
end
```

## Performance Benchmarks (Estimated)

### Current JSON Approach
- **Write Performance**: 16.8ms per insert (single)
- **Batch Write**: ~300ms for 50 records
- **Query Performance**: 100-500ms for method lookups (JSON scan)

### Hybrid Normalized Approach
- **Write Performance**: 0.5ms per insert (single)
- **Batch Write**: ~50ms for 50 records  
- **Query Performance**: 5-15ms for method lookups (indexed)

### Storage Efficiency
- **Current**: ~16KB per test case
- **Normalized**: ~2KB per test case (87% reduction)

## Recommended Implementation Plan

### **Start with Approach 2 (Hybrid Normalized)**

**Why this approach:**
1. **Best performance/complexity balance**
2. **Immediate query performance gains**
3. **Future-proof scalability**
4. **Clear data relationships**

### **Migration Strategy:**
1. **Week 1**: Create new schema alongside existing
2. **Week 2**: Implement dual-write mode
3. **Week 3**: Migrate existing data in batches
4. **Week 4**: Update queries and remove old schema

### **Fallback Plan:**
If migration complexity is too high, implement **Approach 1** (Optimized JSON) first for immediate gains, then plan **Approach 2** for future.

## Quick Wins You Can Implement Today

1. **Batch Size Optimization**
```ruby
# Increase batch size for better throughput
config.store = Coverband::Storage::MysqlJsonStore.new(
  batch_size: 200,  # Increase from 50
  chunk_size: 50    # Increase from 10
)
```

2. **Add Strategic Indexes**
```sql
-- Add indexes for your most common queries
CREATE INDEX idx_test_case_files ON test_coverage 
(test_case_id, (CAST(JSON_KEYS(file_paths) AS CHAR(2000) ARRAY)));
```

3. **Compress JSON Data**
```ruby
def compress_json(data)
  # Remove unnecessary whitespace, use shorter keys
  JSON.generate(data, {space: '', object_nl: '', array_nl: ''})
end
```

This approach will give you the robustness, performance, and scalability you need while maintaining consistency between PR analysis and stored data. 