# frozen_string_literal: true

require 'httparty'
require 'json'
require 'openssl'
require 'socket'

require_relative '../ghb'

module GHB
  # Centralized GitHub API client with shared headers, retry logic, and error handling.
  class GitHubAPIClient
    GRAPHQL_URL = 'https://api.github.com/graphql'
    MAX_RETRIES = 3
    # Cap a single rate-limit back-off so a far-future X-RateLimit-Reset can't hang CI.
    MAX_RETRY_WAIT = 60
    # Bound every request so a stalled connection can't hang the CLI indefinitely
    # (and so the Net::OpenTimeout / Net::ReadTimeout retry path can actually fire).
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    RETRYABLE_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError].freeze

    private_constant :GRAPHQL_URL
    private_constant :MAX_RETRIES
    private_constant :MAX_RETRY_WAIT
    private_constant :OPEN_TIMEOUT
    private_constant :READ_TIMEOUT
    private_constant :RETRYABLE_ERRORS

    def initialize(token)
      @token = token
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

    # Runs a GraphQL query or mutation and returns its `data` hash.
    #
    # GraphQL is needed for the settings the classic REST API cannot represent
    # (notably branch-protection actor allowlists). It reports failures inside a
    # 200 response's `errors` array rather than through the status code, so those
    # are surfaced here as GitHubAPIError just like a failed REST call.
    def graphql(query, variables: {})
      response = execute(
        :post,
        GRAPHQL_URL,
        body: { query: query, variables: variables },
        headers: { Authorization: "bearer #{@token}", Accept: 'application/json' }
      )

      payload =
        begin
          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise(GitHubAPIError, "GraphQL response was not valid JSON: #{e.message}")
        end

      errors = payload['errors']

      if errors.is_a?(Array) && errors.any?
        messages = errors.filter_map { |error| error['message'] }
        raise(GitHubAPIError, "GraphQL request failed: #{messages.join('; ')}")
      end

      payload['data'] || {}
    end

    private

    def execute(method, url, body: nil, headers: {}, expected_codes: [200])
      options = { headers: @headers.merge(headers), open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT }
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

    # A secondary limit answers 403 with Retry-After while the primary quota,
    # and so X-RateLimit-Remaining, is untouched.
    def rate_limited?(response)
      return true if response.code == 429
      return false unless response.code == 403

      response.headers['x-ratelimit-remaining'].to_s == '0' ||
        !response.headers['retry-after'].nil? ||
        response.body.to_s.include?('secondary rate limit')
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
