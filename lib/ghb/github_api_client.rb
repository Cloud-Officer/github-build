# frozen_string_literal: true

require 'httparty'
require 'json'
require 'openssl'
require 'socket'

require_relative '../ghb'

module GHB
  # Centralized GitHub API client with shared headers, retry logic, and error handling.
  class GitHubAPIClient
    MAX_RETRIES = 3
    # Cap a single rate-limit back-off so a far-future X-RateLimit-Reset can't hang CI.
    MAX_RETRY_WAIT = 60
    RETRYABLE_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError].freeze

    private_constant :MAX_RETRIES
    private_constant :MAX_RETRY_WAIT
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

      if expected_codes && !expected_codes.include?(response.code)
        body = response.body.to_s.strip[0, 1000]
        raise(GitHubAPIError, "HTTP #{method.upcase} #{url} failed: #{response.code} #{response.message}#{" — #{body}" unless body.to_s.empty?}")
      end

      response
    end

    def with_retries
      retries = 0

      loop do
        response = yield
        return response unless retries < MAX_RETRIES && retryable_response?(response)

        retries += 1
        sleep(retry_wait(response, retries))
      rescue *RETRYABLE_ERRORS
        retries += 1
        raise if retries > MAX_RETRIES

        sleep(retries)
      end
    end

    # Retry on transient server errors (5xx) and on rate limiting.
    def retryable_response?(response)
      response.code >= 500 || rate_limited?(response)
    end

    # GitHub signals rate limiting with 429, or 403 + X-RateLimit-Remaining: 0
    # (primary and secondary/abuse limits).
    def rate_limited?(response)
      return true if response.code == 429

      response.code == 403 && response.headers['x-ratelimit-remaining'].to_s == '0'
    end

    # Honor Retry-After / X-RateLimit-Reset for rate-limited responses (capped);
    # otherwise fall back to linear back-off (1s, 2s, 3s).
    def retry_wait(response, retries)
      return retries unless rate_limited?(response)

      wait = rate_limit_wait(response)
      wait.positive? ? [wait, MAX_RETRY_WAIT].min : retries
    end

    def rate_limit_wait(response)
      retry_after = response.headers['retry-after']
      return Integer(retry_after, 10, exception: false) || 0 if retry_after

      reset = response.headers['x-ratelimit-reset']
      return 0 unless reset

      [(Integer(reset, 10, exception: false) || 0) - Time.now.to_i, 0].max
    end
  end
end
