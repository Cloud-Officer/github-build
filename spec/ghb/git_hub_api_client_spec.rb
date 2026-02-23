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
        .to(raise_error(RuntimeError, /HTTP GET.*failed.*404/))
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
        .to(raise_error(RuntimeError, /HTTP PUT.*failed.*422/))
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
        .to(raise_error(RuntimeError, /HTTP PATCH.*failed.*500/))
    end

    it 'skips validation when expected_codes is nil' do
      stub_request(:patch, base_url)
        .to_return(status: 422, body: '{}')

      response = client.patch(base_url, expected_codes: nil)
      expect(response.code).to(eq(422))
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

    it 'raises after exhausting retries on 5xx' do
      stub_request(:get, base_url)
        .to_return(status: 503, body: '{}')

      expect { client.get(base_url) }
        .to(raise_error(RuntimeError, /HTTP GET.*failed.*503/))
    end

    it 'retries on Net::OpenTimeout' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      call_count = 0

      allow(HTTParty).to(receive(:get)) do
        call_count += 1
        raise(Net::OpenTimeout, 'execution expired') if call_count < 3

        double('response', code: 200, body: '{}', message: 'OK') # rubocop:disable RSpec/VerifiedDoubles
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

        double('response', code: 200, body: '{}', message: 'OK') # rubocop:disable RSpec/VerifiedDoubles
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

        double('response', code: 200, body: '{}', message: 'OK') # rubocop:disable RSpec/VerifiedDoubles
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
        .to(raise_error(RuntimeError, /HTTP GET.*failed.*422/))

      expect(a_request(:get, base_url)).to(have_been_made.once)
    end
  end
end
