#!/bin/bash

# Number of parallel requests to make
NUM_REQUESTS=100

# Function to generate a random name
generate_random_name() {
  cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1
}

# Function to make a single request
make_request() {
  local request_num=$1
  local random_name=$(generate_random_name)
  local test_case_id=$(shuf -i 100000-999999 -n 1) # Generate random 6-digit test case ID
  echo "Starting request $request_num for requester group with name: $random_name, Test Case ID: $test_case_id"
  
  # Construct the data payload
  local data_payload="utf8=%E2%9C%93&authenticity_token=Ude30xUqktX4y5eigYRQLMQdC5CpxBj6bewzD8fdxUFtrk9zJqi%2BUd6QYYgQAZy6baX2q5QsIunaqrcTnNXGhQ%3D%3D&itil_requester_group%5Bname%5D=${random_name}&itil_requester_group%5Bdescription%5D=&itil_requester_group%5Brequesters_list%5D=&itil_requester_group%5Bmanual_addition%5D=true"

  curl 'https://share-ruby-upgrade-x-9.freshtva.com/ws/1/admin/requester_groups' \
    -H "X-TEST-CASE-ID: $test_case_id" \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: en-GB,en-US;q=0.9,en;q=0.8' \
    -H 'cache-control: max-age=0' \
    -H 'content-type: application/x-www-form-urlencoded' \
    -b '_BEAMER_USER_ID_bxOQALFw21023=57fdb99b-6ab0-4348-9b12-6b004b42a564; _BEAMER_FIRST_VISIT_bxOQALFw21023=2024-09-25T06:47:45.225Z; _x_m=x_c; _x_d=x_3; _x_w=2; order=name; order_type=ASC; contacts_sort=all; order_by=name; contract-filter-closed=false; wf_filter=open_or_pending; wf_order=created_at; wf_order_type=desc; filter_name=new_and_my_open; current_workspace_id=1; helpdesk_node_session=11dc16719e3ba6172628711a26a9f1221a13f00e774502db68e636ba0db4b5d7e0557a4388acf042927db0e3393d6f2f40251ea35e0f80309cab6cfc6c5b5aee; user_credentials=BAhJIgGGM2YxMmQ4NzgzYTE3ZGY0OGNiZGM1NjBlOWI0MzVjZTEzYzU1ZTBhYTY2NGY0MWE4ZDAyZDMwZTNjNDUwNGI3MDgzYjE1YWQzZTQ3YWQ2ZmM4N2UwNjdlN2E4NjU1ZGZkMGUyYjY1OTBiMDE3YzViNjg1ODEyMjljMzg3Y2ZlZmI6OjczMjgGOgZFVA%3D%3D--71888a42bdb15f1e5f2185140663b5c2498058a6; helpdesk_url=share-ruby-upgrade-x-9.freshtva.com; fw-session-id=1521e87a1827df0c79095f1ec4d0f27f757d2af9a725385b19e6a25baa0f087ef528ca08f6f69c7ecf6cf41c78dc80353c482a6f19f488e02f23f9234aa187ff77ff1b518bd590661978495e74aebc57b3329ece588bfe2ed4f6367e2cef5872cf25c1dc4ec33ea7d747c688e5978650da9e4e1f22e9bbf081f20bcd3eb8c725; _BEAMER_LAST_POST_SHOWN_bxOQALFw21023=111243826; _BEAMER_BOOSTED_ANNOUNCEMENT_DATE_bxOQALFw21023=2025-06-11T04:00:10.314Z; _hp2_props.3819588117=%7B%22account_id%22%3A%221250000648%22%2C%22account_state%22%3A%22trial%22%2C%22account_plan%22%3A%22enterprise%22%2C%22workspace_id%22%3A1%2C%22workspace_type%22%3A%22global%22%2C%22workspace_state%22%3A%22active%22%2C%22screenSize%22%3A%221728x1117%22%2C%22screenResolution%22%3A%223801x2457%22%2C%22playGodPrivileges%22%3A%22true%22%2C%22workloadPrivilege%22%3A%22Workload%20Agent%22%7D; _hp2_ses_props.3819588117=%7B%22r%22%3A%22https%3A%2F%2Fshare-ruby-upgrade-x-9.freshtva.com%2Fitil%2Frequesters%2Fnew%22%2C%22ts%22%3A1750042495509%2C%22d%22%3A%22share-ruby-upgrade-x-9.freshtva.com%22%2C%22h%22%3A%22%2Fws%2F1%2Fadmin%2Fhome%22%7D; _BEAMER_FILTER_BY_URL_bxOQALFw21023=true; _BEAMER_FILTER_BY_URL_bxOQALFw21023=true; _itildesk_session=OVp3ZDZ1VDZaUU9ZWHhRN01kVmxmRlRDczhFNXN3ZGRWblhrKzYwSWdLMDJjR1dqM2wrVXV3Q3VZNVpCZkIrbHRDSU1wbjNTamtVMXBRbi9NY2YwQ0ZhVUU3SjNsV25VTzVhdmxUSHFkYzNQakhmWDRWVU9EdWJDYTRtVVVaTXpJU2tzT3MvL3YvVnpYQlRXMlUrZGM2TjM1Smd3NXgxRHNWbzJMQzRrZTU3VkdhQytHaTJsQ2xwTGVSL3R5d0NocStSMVNKVUd3Ym42TGxWSzh0QkxKcmJBWXAwdFVOSE9JL2hzZlIveUlyL2tSWm1COXYyUFREMjlGRWNsNW02SFVxcmFIbVV0N2V5Tnp6UzF1RHR4OVpvdldHc0dGUWMycDlKRklHR0FGODRpVkFnMngyclN5MmdmdkZ1N2pONGYwSWpxQVhNa1FEVjBIbC81eE44eGNwRkFuY3VZd0xyaVpIejdhMi8rNk1uUDVvNjRJQmFpTkNYMEMvWXJGUjB4YnNoNFVpaGYreGZwR1BKU2RMaEJjU25OV0N0clNRQU5kMWpNeVlaVGdJU2Z3ZHhZbXRvT0ZUTFFNNlRnR25Bc1JtbWg5NTM0a29RemcwMmJZTExMVGpEQ0o2djQ1N0RBYlIrZzNsemh6NXZMVWZwcGtkUDF4KzZZd2tkRUZjN0lZcW80NUYzaFVuK1F2ME1yUnVwNGFKNUVldmZNNnY5OHdHQm9oRDhEOUYrYVQ4a2kwWW9ZZGgycUJTYitidmZmRmRjRzRFTXFYVzVBaGFSTlFEb3NSWDU4OTBKUXJHWGJXbURHR3lDT25Nblh6bzNYSzFMYXdsT0FyRlNlUlRFSVFuckIwU2llOEltTkdweVpYQVBSN25FVXdHSWVjZXFoSnlZVlQ5RWhFeFIrOVdubGlnMHI5VUVxTXRTRkJoZkZSTVdtY0g3YlltOWFaR011NTdiUzZ5UElVUjVLNmxJc2NyMS9sZWtiUURJNjk2a3NFVUJpRHZkRVRxdHRERUV0b1hSbFJsMGpraDhnVHo4THdZQUR2K0dxL3MyZVlzaTFFU0xWUDdNQTlnWml0T2tnRUxFQ3I3cTJTRHdxVnhHWkFQd3BWeUV2TERCL1ZETVVSV3pWS25LUVJTQWhsQWw2bE5td2JuZlpLSGt1VzhWTWlRY2xlalNxd1ZvVkZ1UWtPRmxoSTQzN2Q0czAzcmhNRVJsRWJTNnpLMlU1clRnQ1oxczRnZVg5L2lsSU5DQ2Z4SVNYQlB6eWduMXZGVGh1Sk5HN0FiYzZ1MFFWcTdJaFV0SmlzN2pHeG9NUlJPWC8wczdSWXVNcTFEalZ1NXpoSkQwUloyUWhyc0NiVGs3dEFhck5HSnhDRG1Eei9FYzNydUNWSFE9PS0tYUZOcyt5QUU5cTdURHlKSkF2ci9tdz09--36d45c24a027c908e5e68aff89e39c68a8b328fc' \
    -H 'origin: https://share-ruby-upgrade-x-9.freshtva.com' \
    -H 'priority: u=0, i' \
    -H 'referer: https://share-ruby-upgrade-x-9.freshtva.com/ws/1/admin/requester_groups/new' \
    -H 'sec-ch-ua: "Google Chrome";v="135", "Not-A.Brand";v="8", "Chromium";v="135"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "macOS"' \
    -H 'sec-fetch-dest: document' \
    -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: same-origin' \
    -H 'sec-fetch-user: ?1' \
    -H 'upgrade-insecure-requests: 1' \
    -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36' \
    --data-raw "$data_payload"

  echo "Finished request $request_num for requester group with name: $random_name, Test Case ID: $test_case_id"
}

echo "Starting $NUM_REQUESTS parallel requests for requester groups..."

# Launch all requests in parallel
for i in $(seq 1 $NUM_REQUESTS); do
  make_request $i &
done

# Wait for all background processes to complete
wait

echo "All requester group requests completed!"
