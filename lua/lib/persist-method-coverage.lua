-- Script to persist method coverage data and test case mappings for methods.
--
-- KEYS[1]: The Redis key for the method coverage hash of a specific file.
-- ARGV[1]: A JSON string containing the payload:
--          {
--            "ttl": <integer_seconds_for_expiration_OR_nil>,
--            "meta": {
--              "file": "<relative_file_path_string>",
--              "file_hash": "<file_content_hash_string>",
--              "first_updated_at": <timestamp_integer_seconds_string>,
--              "last_updated_at": <timestamp_integer_seconds_string>
--            },
--            "coverage": {
--              "<method_fullname_1>": <count_integer_1>,
--              "<method_fullname_2>": <count_integer_2>,
--              ...
--            },
--            "test_case_id": "<augmented_test_case_id_string_OR_empty_string>"
--          }

local payload_json = ARGV[1]

-- Helper function to get keys of a table for debugging
local function get_table_keys(tbl)
  if type(tbl) ~= 'table' then
    return ""
  end
  local keys = {}
  for k, _ in pairs(tbl) do
    table.insert(keys, tostring(k))
  end
  return table.concat(keys, ", ")
end

if payload_json == nil then
  return redis.error_reply("ARGV[1] (payload_json) is nil")
end
if type(payload_json) ~= 'string' then
  return redis.error_reply("ARGV[1] (payload_json) is not a string. Type: " .. type(payload_json))
end
if payload_json == "" then
  return redis.error_reply("ARGV[1] (payload_json) is an empty string")
end

local success, payload = pcall(cjson.decode, payload_json)

if not success then
  return redis.error_reply("Failed to decode JSON. Error: " .. tostring(payload) .. ". Original JSON: " .. payload_json)
end

if payload == nil then
  return redis.error_reply("Decoded payload is nil (likely from JSON 'null'). Original JSON: " .. payload_json)
end

if type(payload) ~= "table" then
  return redis.error_reply("Decoded payload is not a table. Type: " .. type(payload) .. ". Original JSON: " .. payload_json)
end

if payload.meta == nil then
  return redis.error_reply("payload.meta is nil. Payload keys: [" .. get_table_keys(payload) .. "]. Original JSON: " .. payload_json)
end

if type(payload.meta) ~= "table" then
  return redis.error_reply("payload.meta is not a table. Type: " .. type(payload.meta) .. ". Payload keys: [" .. get_table_keys(payload) .. "]. Original JSON: " .. payload_json)
end

local method_key = KEYS[1]

-- Set metadata fields
redis.call('HSETNX', method_key, 'file', payload.meta.file)
redis.call('HSETNX', method_key, 'file_hash', payload.meta.file_hash)
redis.call('HSETNX', method_key, 'first_updated_at', payload.meta.first_updated_at)
-- Always update last_updated_at
redis.call('HSET', method_key, 'last_updated_at', payload.meta.last_updated_at)

-- Increment method counts
if payload.coverage == nil or type(payload.coverage) ~= 'table' then
  return redis.error_reply("payload.coverage is nil or not a table. Payload keys: [" .. get_table_keys(payload) .. "]. Original JSON: " .. payload_json)
end
for method_name, count in pairs(payload.coverage) do
  if count > 0 then
    redis.call('HINCRBY', method_key, method_name, count)
  end
end

-- Update test_cases JSON if test_case_id is provided and not empty
if payload.test_case_id and #payload.test_case_id > 0 then
  if type(payload.test_case_id) ~= 'string' then
     return redis.error_reply("payload.test_case_id is not a string. Type: " .. type(payload.test_case_id))
  end

  local test_cases_json = redis.call('HGET', method_key, 'test_cases')
  local test_cases_map

  if test_cases_json and #test_cases_json > 0 then
    local tc_success, tc_map = pcall(cjson.decode, test_cases_json)
    if not tc_success then
      -- Existing data is corrupt, log or handle, then reset
      test_cases_map = {}
    else
      test_cases_map = tc_map
    end
    if type(test_cases_map) ~= 'table' then
      test_cases_map = {}
    end
  else
    test_cases_map = {}
  end

  -- Debug: Output the full test_case_id to Redis log
  redis.log(redis.LOG_WARNING, "Processing test_case_id: " .. payload.test_case_id)

  for method_name, count in pairs(payload.coverage) do
    if count > 0 then
      if test_cases_map[method_name] == nil or type(test_cases_map[method_name]) ~= 'table' then
        test_cases_map[method_name] = {}
      end
      
      -- Store the test_case_id directly in an array instead of using it as a table key
      local method_test_cases = test_cases_map[method_name]
      local found = false
      
      -- Check if this test_case_id already exists in the array
      for i, existing_id in ipairs(method_test_cases) do
        if existing_id == payload.test_case_id then
          found = true
          break
        end
      end
      
      -- Add it only if it's not already in the array
      if not found then
        table.insert(method_test_cases, payload.test_case_id)
      end
    end
  end

  -- No need for the extra transformation step, the IDs are already stored as an array
  local final_test_cases_map_for_json = {}
  for method_name, ids_array in pairs(test_cases_map) do
    if type(ids_array) == 'table' then
      -- Just sort the array to maintain consistent ordering
      table.sort(ids_array)
      final_test_cases_map_for_json[method_name] = ids_array
    end
  end

  redis.call('HSET', method_key, 'test_cases', cjson.encode(final_test_cases_map_for_json))
end

-- Set TTL if provided
if payload.ttl ~= nil then -- Check if the key 'ttl' exists in the payload table
  if payload.ttl == cjson.null then
    -- TTL is explicitly set to null (from JSON null), means no expiration. Do nothing.
  elseif type(payload.ttl) == 'number' then
    if payload.ttl > 0 then
      redis.call('EXPIRE', method_key, tonumber(payload.ttl)) -- Ensure it's passed as number
    end
  else
    -- payload.ttl exists, is not cjson.null, and is not a number. This is an error.
    return redis.error_reply("payload.ttl is present but is not a number nor null. Type: " .. type(payload.ttl) .. ". Value: " .. tostring(payload.ttl))
  end
end

return redis.status_reply('OK')
