# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Analyzes the diff content to identify added, modified, and deleted methods.
def analyze_diff_content(diff, pr_number)
  file_changes = {}
  current_file = nil
  current_method = nil

  diff.each_line do |line|
    if line.start_with?('diff --git')
      # When a new file is encountered, reset the state.
      current_file = line.match(%r{^diff --git a/(.+\.rb) b/(.+\.rb)})&.[](2)
      if current_file
        file_changes[current_file] = { added: [], modified: [], deleted: [] }
      end
      current_method = nil
      next
    end

    next unless current_file

    if line.start_with?('@@')
      # A new hunk is starting. Try to find the method name in the hunk header.
      match = line.match(/@@.*@@.*?(def\s+([a-zA-Z_][\w.]*[!?=]?))/)
      current_method = match[2] if match
      next
    end

    # A method definition inside the hunk (as a context line) is also a good indicator.
    unless current_method
      match = line.match(/^\s*def\s+([a-zA-Z_][\w.]*[!?=]?)/)
      current_method = match[1] if match
    end

    # Handle new file additions.
    if line.start_with?('--- /dev/null')
      # Mark all methods in the new file as added.
      new_file_methods = diff.scan(/^\+def\s+([a-zA-Z_][\w.]*[!?=]?)/).flatten
      file_changes[current_file][:added].concat(new_file_methods)
      next
    end

    # A line was added or removed.
    if (line.start_with?('+') || line.start_with?('-')) && !line.start_with?('+++') && !line.start_with?('---')
      if line.start_with?('+def')
        method_name = line.match(/^\+def\s+([a-zA-Z_][\w.]*[!?=]?)/)[1]
        file_changes[current_file][:added] << method_name
      elsif line.start_with?('-def')
        method_name = line.match(/^-def\s+([a-zA-Z_][\w.]*[!?=]?)/)[1]
        file_changes[current_file][:deleted] << method_name
      elsif current_method
        # This is a change within a method.
        changes = file_changes[current_file]
        # Mark as modified only if it's not already part of an added/deleted method.
        if !changes[:added].include?(current_method) &&
           !changes[:deleted].include?(current_method) &&
           !changes[:modified].include?(current_method)
          changes[:modified] << current_method
        end
      end
    end
  end

  # Remove keys with empty arrays
  file_changes.each do |file, changes|
    changes.reject! { |_key, value| value.empty? }
  end

  { pr_number => file_changes }
end

# Analyze a list of GitHub pull requests to identify added, modified, and deleted methods.
def analyze_pr_changes(pr_numbers)
  # Read the GitHub token from the environment variable
  github_token = ENV['GITHUB_TOKEN']

  unless github_token
    puts "Error: GITHUB_TOKEN environment variable is not set."
    return
  end

  all_changes = {}

  pr_numbers.each do |pr_number|
    # Construct the GitHub API URL for the pull request diff
    repo = 'itildesk' # Hardcoded repository name
    url = URI("https://api.github.com/repos/freshdesk/#{repo}/pulls/#{pr_number}")

    puts "Requesting URL: #{url}" # Debug statement to print the URL

    # Set up the HTTP request
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(url)
    request['Authorization'] = "Bearer #{github_token}"
    request['Accept'] = 'application/vnd.github.v3.diff'

    # Fetch the diff
    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      puts "Error fetching PR diff: #{response.code} #{response.message}"
      next
    end

    diff_content = response.body
    all_changes.merge!(analyze_diff_content(diff_content, pr_number))
  end

  # Save the results to a JSON file
  File.write('pr_method_changes.json', JSON.pretty_generate(all_changes))
  puts "Results saved to pr_method_changes.json"
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts "Usage: ruby analyze_pr_changes.rb <pr_number1> <pr_number2> ..."
    exit 1
  end

  pr_numbers = ARGV
  analyze_pr_changes(pr_numbers)
end

# ruby analyze_pr_changes.rb 31475 32162 31475