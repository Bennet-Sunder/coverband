#!/bin/bash

# Number of parallel requests to make
NUM_REQUESTS=10
SUCCESSFUL_REQUESTS=0

# Start time measurement
START_TIME=$(date +%s)

# Generate a random 5-digit starting test case ID
BASE_TEST_CASE_ID=$((RANDOM % 90000 + 10000))
echo "Using base test case ID: $BASE_TEST_CASE_ID"

# Function to make a single request
make_request() {
  local request_num=$1
  local random_suffix=$((RANDOM % 10000))
  
  # Calculate sequential test case ID
  local test_case_id=$((BASE_TEST_CASE_ID + request_num - 1))
  
  echo "Starting request $request_num with test case ID: $test_case_id"
  
  # Generate a unique group name to avoid conflicts on subsequent runs
  local group_name="Linux Support Team $request_num-$random_suffix"
  
  # Make the request and capture HTTP status code
  response=$(curl -s -o /dev/null -w "%{http_code}" -u R147nG8cTWwsXbyyO6US:X \
    -H "Content-Type:application/json" \
    -H "X-TEST-CASE-ID: $test_case_id" \
    -X POST \
    -d "{\"name\":\"$group_name\", \"description\":\"Support team for Linux VMs, workstations, and servers\", \"unassigned_for\":\"30m\", \"members\": [], \"observers\": []}" \
    "http://localhost.freshservice-dev.com:3000/api/v2/groups")
  
  # Check if response indicates success (2xx status code)
  if [[ $response =~ ^2[0-9][0-9]$ ]]; then
    echo "Request $request_num completed successfully with status code $response"
    # Use a file to communicate between processes
    echo "success" >> /tmp/coverband_debug_results
  else
    echo "Request $request_num failed with status code $response"
  fi
}

echo "Starting $NUM_REQUESTS requests to local development environment..."

# Clear the temporary results file
rm -f /tmp/coverband_debug_results

# Launch all requests in parallel
for i in $(seq 1 $NUM_REQUESTS); do
  make_request $i &
done

# Wait for all background processes to complete
wait

# Calculate successful requests
if [ -f /tmp/coverband_debug_results ]; then
  SUCCESSFUL_REQUESTS=$(cat /tmp/coverband_debug_results | wc -l | tr -d ' ')
  rm -f /tmp/coverband_debug_results
fi

# Calculate end time and duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "=========================================="
echo "All requests completed!"
echo "Total successful requests: $SUCCESSFUL_REQUESTS out of $NUM_REQUESTS"
echo "Total execution time: $DURATION seconds"
echo "Test case IDs used: $BASE_TEST_CASE_ID through $((BASE_TEST_CASE_ID + NUM_REQUESTS - 1))"
echo "=========================================="