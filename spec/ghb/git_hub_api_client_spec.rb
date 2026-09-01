# frozen_string_literal: true

RSpec.describe(GHB::GitHubAPIClient) do
  let(:token)           { 'test-token-123'                         }
  let(:client)          { described_class.new(token)               }
  let(:base_url)        { 'https://api.github.com/repos/org/repo'  }
  let(:default_headers) do
    {
      Authorization: 'token test-token-123',
      Accept: 'application/vnd.github.v3+json'
    }
  end

  before do
    allow(client).to(receive(:sleep))
  end

  describe '#get' do
    it 'sends GET request with auth headers' do
      stub_request(:get, base_url)
        .with(headers: default_headers)
        .to_return(status: 200, body: '{"ok":true}')

      response = client.get(base_url)
      expect(response.code).to(eq(200))
    end

    it 'raises on unexpected status code' do
      stub_request(:get, base_url)
        .to_return(status: 404, body: '{"message":"Not Found"}')

      expect { client.get(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP GET.*failed.*404/))
    end

    it 'accepts custom expected_codes' do
      stub_request(:get, base_url)
        .to_return(status: 404, body: '{}')

      response = client.get(base_url, expected_codes: [200, 404])
      expect(response.code).to(eq(404))
    end

    it 'skips validation when expected_codes is nil' do
      stub_request(:get, base_url)
        .to_return(status: 403, body: '{"message":"Forbidden"}')

      response = client.get(base_url, expected_codes: nil)
      expect(response.code).to(eq(403))
    end

    it 'bounds every request with open and read timeouts' do
      allow(HTTParty).to(receive(:get).and_return(instance_double(HTTParty::Response, code: 200, body: '{}')))

      client.get(base_url)

      expect(HTTParty).to(have_received(:get).with(base_url, hash_including(open_timeout: 10, read_timeout: 30)))
    end
  end

  describe '#put' do
    it 'sends PUT request with auth headers' do
      stub_request(:put, base_url)
        .with(headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.put(base_url)
      expect(response.code).to(eq(200))
    end

    it 'serializes body as JSON' do
      stub_request(:put, base_url)
        .with(body: '{"key":"value"}', headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.put(base_url, body: { key: 'value' })
      expect(response.code).to(eq(200))
    end

    it 'accepts custom expected_codes' do
      stub_request(:put, base_url)
        .to_return(status: 204, body: '')

      response = client.put(base_url, expected_codes: [200, 204])
      expect(response.code).to(eq(204))
    end

    it 'raises on unexpected status code' do
      stub_request(:put, base_url)
        .to_return(status: 422, body: '{"message":"Unprocessable"}')

      expect { client.put(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP PUT.*failed.*422/))
    end

    it 'includes the response body in the error for diagnosis' do
      stub_request(:put, base_url)
        .to_return(status: 422, body: '{"message":"Invalid request","errors":[{"field":"required_status_checks"}]}')

      expect { client.put(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /Invalid request.*required_status_checks/))
    end

    it 'truncates an oversized response body to 1000 characters' do
      stub_request(:put, base_url)
        .to_return(status: 422, body: "#{'x' * 5000}END")

      expect { client.put(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /— x{1000}\z/))
    end
  end

  describe '#post' do
    it 'sends POST request with auth headers' do
      stub_request(:post, base_url)
        .with(headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.post(base_url)
      expect(response.code).to(eq(200))
    end

    it 'serializes body as JSON' do
      stub_request(:post, base_url)
        .with(body: '{"data":"test"}', headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.post(base_url, body: { data: 'test' })
      expect(response.code).to(eq(200))
    end

    it 'merges custom headers with defaults' do # rubocop:disable RSpec/ExampleLength
      custom_accept = 'application/vnd.github.zzzax-preview+json'

      stub_request(:post, base_url)
        .with(headers: default_headers.merge(Accept: custom_accept))
        .to_return(status: 200, body: '{}')

      response = client.post(base_url, headers: { Accept: custom_accept })
      expect(response.code).to(eq(200))
    end

    it 'accepts custom expected_codes' do
      stub_request(:post, base_url)
        .to_return(status: 204, body: '')

      response = client.post(base_url, expected_codes: [200, 204])
      expect(response.code).to(eq(204))
    end
  end

  describe '#patch' do
    it 'sends PATCH request with auth headers' do
      stub_request(:patch, base_url)
        .with(headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.patch(base_url)
      expect(response.code).to(eq(200))
    end

    it 'serializes body as JSON' do
      stub_request(:patch, base_url)
        .with(body: '{"setting":true}', headers: default_headers)
        .to_return(status: 200, body: '{}')

      response = client.patch(base_url, body: { setting: true })
      expect(response.code).to(eq(200))
    end

    it 'raises on unexpected status code' do
      stub_request(:patch, base_url)
        .to_return(status: 500, body: '{"message":"Internal Server Error"}')

      expect { client.patch(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP PATCH.*failed.*500/))
    end

    it 'skips validation when expected_codes is nil' do
      stub_request(:patch, base_url)
        .to_return(status: 422, body: '{}')

      response = client.patch(base_url, expected_codes: nil)
      expect(response.code).to(eq(422))
    end
  end

  describe '#graphql' do
    let(:graphql_url) { 'https://api.github.com/graphql' }

    it 'posts the query and variables and returns the data hash' do # rubocop:disable RSpec/ExampleLength
      stub_request(:post, graphql_url)
        .with(
          body: { query: 'query { viewer { login } }', variables: { owner: 'org' } }.to_json,
          headers: { Authorization: 'bearer test-token-123', Accept: 'application/json' }
        )
        .to_return(status: 200, body: { data: { viewer: { login: 'octocat' } } }.to_json)

      expect(client.graphql('query { viewer { login } }', variables: { owner: 'org' }))
        .to(eq(JSON.parse('{"viewer":{"login":"octocat"}}')))
    end

    it 'defaults variables to an empty hash' do
      stub_request(:post, graphql_url)
        .with(body: { query: 'query { viewer { login } }', variables: {} }.to_json)
        .to_return(status: 200, body: '{"data":{}}')

      expect(client.graphql('query { viewer { login } }')).to(eq({}))
    end

    # GraphQL reports failures inside a 200 response, so the status code alone
    # would let a failed query look like a successful one.
    it 'raises when a 200 response carries a GraphQL errors array' do
      stub_request(:post, graphql_url)
        .to_return(status: 200, body: { data: nil, errors: [{ message: 'Resource not accessible by integration' }, { message: 'Field does not exist' }] }.to_json)

      expect { client.graphql('query { viewer { login } }') }
        .to(raise_error(GHB::GitHubAPIError, 'GraphQL request failed: Resource not accessible by integration; Field does not exist'))
    end

    it 'ignores an empty errors array' do
      stub_request(:post, graphql_url)
        .to_return(status: 200, body: { data: { ok: true }, errors: [] }.to_json)

      expect(client.graphql('query { viewer { login } }')).to(eq(JSON.parse('{"ok":true}')))
    end

    it 'returns an empty hash when data is null' do
      stub_request(:post, graphql_url)
        .to_return(status: 200, body: '{"data":null}')

      expect(client.graphql('query { viewer { login } }')).to(eq({}))
    end

    it 'raises when the response body is not valid JSON' do
      stub_request(:post, graphql_url)
        .to_return(status: 200, body: '<html>maintenance</html>')

      expect { client.graphql('query { viewer { login } }') }
        .to(raise_error(GHB::GitHubAPIError, /GraphQL response was not valid JSON/))
    end

    it 'raises on an unexpected status code' do
      stub_request(:post, graphql_url)
        .to_return(status: 401, body: '{"message":"Bad credentials"}')

      expect { client.graphql('query { viewer { login } }') }
        .to(raise_error(GHB::GitHubAPIError, /HTTP POST.*graphql failed: 401/))
    end
  end

  describe 'retry logic' do
    it 'retries on 5xx responses' do # rubocop:disable RSpec/ExampleLength
      stub_request(:get, base_url)
        .to_return(status: 503, body: '{}')
        .then.to_return(status: 503, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      response = client.get(base_url)
      expect(response.code).to(eq(200))
    end

    it 'sleeps with a linear back-off (1s, 2s, 3s) between 5xx retries' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_request(:get, base_url)
        .to_return(status: 503, body: '{}')
        .then.to_return(status: 503, body: '{}')
        .then.to_return(status: 503, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      client.get(base_url)

      expect(client).to(have_received(:sleep).with(1).ordered)
      expect(client).to(have_received(:sleep).with(2).ordered)
      expect(client).to(have_received(:sleep).with(3).ordered)
    end

    it 'raises after exhausting retries on 5xx' do
      stub_request(:get, base_url)
        .to_return(status: 503, body: '{}')

      expect { client.get(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP GET.*failed.*503/))
    end

    it 'retries on Net::OpenTimeout' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      call_count = 0

      allow(HTTParty).to(receive(:get)) do
        call_count += 1
        raise(Net::OpenTimeout, 'execution expired') if call_count < 3

        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      response = client.get(base_url)
      expect(response.code).to(eq(200))
      expect(call_count).to(eq(3))
    end

    it 'retries on Net::ReadTimeout' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      call_count = 0

      allow(HTTParty).to(receive(:get)) do
        call_count += 1
        raise(Net::ReadTimeout, 'execution expired') if call_count < 2

        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      response = client.get(base_url)
      expect(response.code).to(eq(200))
      expect(call_count).to(eq(2))
    end

    it 'retries on Errno::ECONNRESET' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      call_count = 0

      allow(HTTParty).to(receive(:get)) do
        call_count += 1
        raise(Errno::ECONNRESET, 'Connection reset by peer') if call_count < 2

        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      response = client.get(base_url)
      expect(response.code).to(eq(200))
      expect(call_count).to(eq(2))
    end

    it 'raises after exhausting retries on network error' do
      allow(HTTParty).to(receive(:get).and_raise(Net::OpenTimeout, 'execution expired'))

      expect { client.get(base_url) }
        .to(raise_error(Net::OpenTimeout))
    end

    it 'does not retry on 4xx responses' do # rubocop:disable RSpec/MultipleExpectations
      stub_request(:get, base_url)
        .to_return(status: 422, body: '{"message":"Unprocessable"}')

      expect { client.get(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP GET.*failed.*422/))

      expect(a_request(:get, base_url)).to(have_been_made.once)
    end

    it 'retries on a 429 rate-limit response' do
      stub_request(:get, base_url)
        .to_return(status: 429, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      expect(client.get(base_url).code).to(eq(200))
    end

    it 'retries on a 403 with X-RateLimit-Remaining: 0 (secondary limit)' do
      stub_request(:get, base_url)
        .to_return(status: 403, headers: { 'X-RateLimit-Remaining': '0' }, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      expect(client.get(base_url).code).to(eq(200))
    end

    it 'retries a 403 secondary rate limit that carries Retry-After with the quota intact' do
      stub_request(:get, base_url)
        .to_return(status: 403, headers: { 'Retry-After': '3', 'X-RateLimit-Remaining': '4999' }, body: '{"message":"You have exceeded a secondary rate limit"}')
        .then.to_return(status: 200, body: '{"ok":true}')

      expect(client.get(base_url).code).to(eq(200))
    end

    it 'retries a 403 whose body names a secondary rate limit even without headers' do
      stub_request(:get, base_url)
        .to_return(status: 403, body: '{"message":"You have exceeded a secondary rate limit. Please wait."}')
        .then.to_return(status: 200, body: '{"ok":true}')

      expect(client.get(base_url).code).to(eq(200))
    end

    it 'honors the Retry-After header for the back-off' do
      stub_request(:get, base_url)
        .to_return(status: 429, headers: { 'Retry-After': '7' }, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      client.get(base_url)

      expect(client).to(have_received(:sleep).with(7))
    end

    it 'honors the X-RateLimit-Reset header (reset minus now) for the back-off' do # rubocop:disable RSpec/ExampleLength
      now = 1_700_000_000
      allow(Time).to(receive(:now).and_return(Time.at(now)))
      stub_request(:get, base_url)
        .to_return(status: 429, headers: { 'X-RateLimit-Reset': (now + 5).to_s }, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      client.get(base_url)

      expect(client).to(have_received(:sleep).with(5))
    end

    it 'caps the X-RateLimit-Reset back-off at MAX_RETRY_WAIT (60s)' do # rubocop:disable RSpec/ExampleLength
      now = 1_700_000_000
      allow(Time).to(receive(:now).and_return(Time.at(now)))
      stub_request(:get, base_url)
        .to_return(status: 429, headers: { 'X-RateLimit-Reset': (now + 9999).to_s }, body: '{}')
        .then.to_return(status: 200, body: '{"ok":true}')

      client.get(base_url)

      expect(client).to(have_received(:sleep).with(60))
    end

    it 'does not treat a plain 403 (no rate-limit header) as retryable' do # rubocop:disable RSpec/MultipleExpectations
      stub_request(:get, base_url)
        .to_return(status: 403, body: '{"message":"Forbidden"}')

      expect { client.get(base_url) }
        .to(raise_error(GHB::GitHubAPIError, /HTTP GET.*failed.*403/))

      expect(a_request(:get, base_url)).to(have_been_made.once)
    end

    [Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError].each do |error|
      it "retries on #{error}" do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        call_count = 0

        allow(HTTParty).to(receive(:get)) do
          call_count += 1
          raise(error) if call_count < 2

          instance_double(HTTParty::Response, code: 200, body: '{}')
        end

        response = client.get(base_url)
        expect(response.code).to(eq(200))
        expect(call_count).to(eq(2))
      end
    end
  end
end
