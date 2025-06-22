#!/bin/bash

# Number of parallel requests to make
NUM_REQUESTS=6

# Function to generate a random email address
generate_random_email() {
  local username=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
  local domain=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z' | fold -w 6 | head -n 1)
  echo "${username}@${domain}.com"
}

# Function to make a single request
make_request() {
  local request_num=$1
  local random_email=$(generate_random_email)
  local test_case_id=$(shuf -i 100000-999999 -n 1) # Generate random 6-digit test case ID
  echo "Starting request $request_num with email: $random_email, Test Case ID: $test_case_id" # Updated echo

curl -v -u vw8C17eAq3El2_4RYa1U:X \
  -H "Content-Type: application/json" \
  -H "X-TEST-CASE-ID: $test_case_id" \
  -H "X-RANDOM-EMAIL: $random_email" \
  -X POST \
  -d '{
    "first_name": "Ron",
    "last_name": "Weasley",
    "job_title": "Student",
    "primary_email": "$random_email",
    "work_phone_number": "62443",
    "mobile_phone_number": "77762443",
    "department_ids": [],
    "can_see_all_tickets_from_associated_departments": false,
    "address": "Gryffindor Tower",
    "time_zone": "Edinburgh",
    "language": "en",
    "background_information": ""
  }' \
  'https://share-ruby-upgrade-x-9.freshtva.com/api/v2/requesters'

  echo "Finished request $request_num with email: $random_email, Test Case ID: $test_case_id" # Updated echo
}

echo "Starting $NUM_REQUESTS parallel requests..."

# Launch all requests in parallel
for i in $(seq 1 $NUM_REQUESTS); do
  make_request $i &
done

# Wait for all background processes to complete
wait

echo "All requests completed!"