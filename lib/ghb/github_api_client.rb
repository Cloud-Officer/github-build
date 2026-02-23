# frozen_string_literal: true

require 'httparty'
require 'json'

module GHB
  # Centralized GitHub API client with shared headers, retry logic, and error handling.
  # Extracts duplicated HTTParty calls from Application#check_repository_settings.
  class GitHubAPIClient
    MAX_RETRIES = 3
    RETRYABLE_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET].freeze

    private_constant :MAX_RETRIES
    private_constant :RETRYABLE_ERRORS

    def initialize(token)
      @headers = {
        Authorization: "token #{token}",
        Accept: 'application/vnd.github.v3+json'
      }
    end

    def get(url, expected_codes: [200])
      execute(:get, url, expected_codes: expected_codes)
    end

    def put(url, body: nil, expected_codes: [200])
      execute(:put, url, body: body, expected_codes: expected_codes)
    end

    def post(url, body: nil, headers: {}, expected_codes: [200])
      execute(:post, url, body: body, headers: headers, expected_codes: expected_codes)
    end

    def patch(url, body: nil, expected_codes: [200])
      execute(:patch, url, body: body, expected_codes: expected_codes)
    end

    private

    def execute(method, url, body: nil, headers: {}, expected_codes: [200])
      options = { headers: @headers.merge(headers) }
      options[:body] = body.to_json if body

      response = with_retries { HTTParty.public_send(method, url, options) }

      raise("HTTP #{method.upcase} #{url} failed: #{response.message} (#{response.code})") if expected_codes && !expected_codes.include?(response.code)

      response
    end

    def with_retries
      retries = 0

      loop do
        response = yield
        return response if retries >= MAX_RETRIES || response.code < 500

        retries += 1
        sleep(retries)
      rescue *RETRYABLE_ERRORS
        retries += 1
        raise if retries > MAX_RETRIES

        sleep(retries)
      end
    end
  end
end
