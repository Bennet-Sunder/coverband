local hmset = function (key, dict)
  if next(dict) == nil then return nil end
  local bulk = {}
  for k, v in pairs(dict) do
    table.insert(bulk, k)
    table.insert(bulk, v)
  end
  return redis.call('HMSET', key, unpack(bulk))
end
local payload = cjson.decode(redis.call('get', (KEYS[1])))
local ttl = payload.ttl
local files_data = payload.files_data
redis.call('DEL', KEYS[1])

for _, file_data in ipairs(files_data) do
  -- Check if file_data and its essential components are usable
  if file_data and file_data.meta and file_data.coverage then
    local hash_key = file_data.hash_key -- Assumes hash_key is always present if file_data is.
    local first_updated_at = file_data.meta.first_updated_at
    file_data.meta.first_updated_at = nil

    hmset(hash_key, file_data.meta)
    redis.call('HSETNX', hash_key, 'first_updated_at', first_updated_at)
    for line, coverage in pairs(file_data.coverage) do
      redis.call("HINCRBY", hash_key, line, coverage)
      if coverage > 0 then
        redis.call("HSET", hash_key, line .. "_last_posted", ARGV[1])
        if ARGV[2] and ARGV[2] ~= "" then
          local main_test_cases_field = "test_cases" -- Constant field name for the overall test cases map
          local existing_overall_test_cases_json = redis.call("HGET", hash_key, main_test_cases_field)
          local all_lines_test_cases_map -- This will be a map of line_number -> array_of_test_ids

          if existing_overall_test_cases_json and existing_overall_test_cases_json ~= cjson.null then
            all_lines_test_cases_map = cjson.decode(existing_overall_test_cases_json)
          else
            all_lines_test_cases_map = {} -- Initialize as an empty Lua map-like table
          end

          -- Get or initialize the array for the current line (use tostring(line) for JSON object keys)
          local line_key = tostring(line)
          local current_line_test_cases_array = all_lines_test_cases_map[line_key]
          if not current_line_test_cases_array or type(current_line_test_cases_array) ~= 'table' then
            current_line_test_cases_array = {}
            all_lines_test_cases_map[line_key] = current_line_test_cases_array
          end

          -- Add ARGV[2] to this line\'s array, ensuring uniqueness
          local new_test_case = ARGV[2]
          local found = false
          for _, tc in ipairs(current_line_test_cases_array) do
            if tc == new_test_case then
              found = true
              break
            end
          end

          if not found then
            table.insert(current_line_test_cases_array, new_test_case)
          end

          local updated_overall_test_cases_json = cjson.encode(all_lines_test_cases_map)
          redis.log(redis.LOG_NOTICE, "Persist-Coverage: Updating overall \'" .. main_test_cases_field .. "\' field. HashKey: " .. hash_key .. " NewValue: " .. updated_overall_test_cases_json)
          redis.call("HSET", hash_key, main_test_cases_field, updated_overall_test_cases_json)
        end
      end
    end
    if ttl and ttl ~= cjson.null then
      redis.call("EXPIRE", hash_key, ttl)
    end
  else
    -- Log if file_data was nil or missing essential components
    local reason = "nil file_data entry"
    if file_data then -- file_data was not nil, so meta or coverage must be missing
      if not file_data.meta and not file_data.coverage then
        reason = "file_data.meta and file_data.coverage are nil"
      elseif not file_data.meta then
        reason = "file_data.meta is nil"
      else -- not file_data.coverage
        reason = "file_data.coverage is nil"
      end
      local hash_key_info = ""
      if file_data.hash_key then
        hash_key_info = " hash_key: " .. tostring(file_data.hash_key)
      end
      redis.log(redis.LOG_WARNING, "Coverband: persist-coverage.lua: Skipping entry because " .. reason .. ". KEYS[1]: " .. KEYS[1] .. hash_key_info)
    else -- file_data itself was nil
      redis.log(redis.LOG_WARNING, "Coverband: persist-coverage.lua: Skipping " .. reason .. " in files_data array. KEYS[1]: " .. KEYS[1])
    end
  end
end
