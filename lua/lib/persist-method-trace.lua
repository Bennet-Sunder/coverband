-- This script atomically stores method trace data and associates it with a test case
-- KEYS[1] = entity_key (request or worker key)
-- KEYS[2] = sizes_key
-- KEYS[3] = test_case_index_key
-- KEYS[4] = test_case_key
--
-- ARGV[1] = trace_json
-- ARGV[2] = entity_id
-- ARGV[3] = test_id
-- ARGV[4] = expiration_seconds (not used in script, applied via Redis EXPIRE commands from Ruby)
-- ARGV[5] = json_size_bytes

-- Store the method trace with TTL (TTL is set by Ruby after script execution)
redis.call('SET', KEYS[1], ARGV[1])

-- Track the size
redis.call('HSET', KEYS[2], ARGV[2], ARGV[5])

-- Add test case to index
redis.call('SADD', KEYS[3], ARGV[3])

-- Associate entity with test case
redis.call('SADD', KEYS[4], ARGV[2])

return 1