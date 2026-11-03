require 'spec_helper'

# What AppnexusApi::Connection gets from Faraday: JSON in and out, HTTP and
# transport errors raised as AppnexusApi errors, rate limiting, re-login.
describe AppnexusApi::Connection, 'over Faraday' do
  include WebMock::API

  let(:uri) { 'https://api.example.test/' }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:connection) { AppnexusApi::Connection.new('uri' => uri, 'token' => 'tok') }
  let(:rate_exceeded) { '{"response":{"error_code":"RATE_EXCEEDED"}}' }
  # The shape AppNexus returns errors in (see spec/fixtures/vcr/publisher_crud.yml).
  let(:not_found_body) do
    '{"response":{"error_id":"SYNTAX","error":"publisher id not found: 925480",' \
      '"error_code":"NOTFOUND_PUBLISHER"}}'
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    stub_request(:get, "#{uri}member")
      .to_return(status: 200, headers: json, body: '{"response":{"status":"OK"}}')
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  it 'parses a JSON response body' do
    stub_request(:get, "#{uri}advertiser?id=1")
      .to_return(status: 200, headers: json, body: '{"response":{"advertiser":{"id":1}}}')

    expect(connection.get('advertiser', 'id' => 1).body).to eq(
      'response' => { 'advertiser' => { 'id' => 1 } }
    )
  end

  it 'sends a Hash body as JSON' do
    stub_request(:post, "#{uri}advertiser")
      .with(body: '{"advertiser":{"name":"x"}}', headers: { 'Content-Type' => 'application/json' })
      .to_return(status: 200, headers: json, body: '{"response":{"status":"OK"}}')

    expect(connection.post('advertiser', 'advertiser' => { 'name' => 'x' }).body['response'])
      .to eq('status' => 'OK')
  end

  it 'returns an empty body as is' do
    stub_request(:get, "#{uri}log-level-data-download").to_return(status: 200, headers: json, body: '')

    expect(connection.get('log-level-data-download').status).to eq(200)
  end

  it 'sets request timeouts, overridable from the config' do
    options = connection.instance_variable_get(:@connection).options
    expect([options.timeout, options.open_timeout]).to eq([300, 30])

    custom = AppnexusApi::Connection.new('uri' => uri, 'token' => 'tok', 'timeout' => 5)
    expect(custom.instance_variable_get(:@connection).options.timeout).to eq(5)
  end

  describe 'HTTP errors' do
    # Before this change every one of these surfaced as a NameError: the rescue
    # named Faraday::Error::TimeoutError, which no Faraday version defines.
    it 'raises NotFound with the AppNexus error in the message' do
      stub_request(:get, "#{uri}publisher").to_return(status: 404, headers: json, body: not_found_body)

      expect { connection.get('publisher') }.to raise_error(
        AppnexusApi::NotFound, /404\nSYNTAX\nNOTFOUND_PUBLISHER\npublisher id not found: 925480/
      )
    end

    it 'maps the status even when the body is not JSON' do
      stub_request(:get, "#{uri}publisher")
        .to_return(status: 502, headers: { 'Content-Type' => 'text/html' }, body: '<html>errors</html>')

      expect { connection.get('publisher') }.to raise_error(AppnexusApi::BadGateway, /: 502\z/)
    end

    it 'maps the status when a JSON error body is malformed' do
      stub_request(:get, "#{uri}publisher").to_return(status: 500, headers: json, body: '{"respo')

      expect { connection.get('publisher') }.to raise_error(AppnexusApi::InternalServerError)
    end

    it 'raises AppnexusApi::Error for an error status it has no class for' do
      stub_request(:get, "#{uri}publisher").to_return(status: 504, body: 'gateway timeout')

      expect { connection.get('publisher') }.to raise_error(AppnexusApi::Error, /: 504/)
    end
  end

  describe 'transport errors' do
    it 'raises AppnexusApi::Timeout when the response times out' do
      stub_request(:get, "#{uri}advertiser").to_raise(Net::ReadTimeout)

      expect { connection.get('advertiser') }.to raise_error(AppnexusApi::Timeout)
    end

    it 'raises AppnexusApi::ConnectionFailed when the connection fails' do
      stub_request(:get, "#{uri}advertiser").to_raise(Errno::ECONNREFUSED)

      expect { connection.get('advertiser') }.to raise_error(AppnexusApi::ConnectionFailed)
    end

    it 'raises AppnexusApi::InvalidJson for a malformed success body' do
      stub_request(:get, "#{uri}advertiser").to_return(status: 200, headers: json, body: '{"respo')

      expect { connection.get('advertiser') }.to raise_error(AppnexusApi::InvalidJson)
    end

    it 'wraps transport errors during login too' do
      stub_request(:post, "#{uri}auth").to_raise(Errno::ECONNREFUSED)

      expect { AppnexusApi::Connection.new('uri' => uri, 'username' => 'u', 'password' => 'p') }
        .to raise_error(AppnexusApi::ConnectionFailed)
    end
  end

  it 'logs in again and retries once after a 401' do
    stub_request(:get, "#{uri}advertiser")
      .to_return({ status: 401, headers: json, body: '{"response":{"error_id":"NOAUTH"}}' },
                 { status: 200, headers: json, body: '{"response":{"status":"OK"}}' })
    stub_request(:post, "#{uri}auth")
      .to_return(status: 200, headers: json, body: '{"response":{"token":"fresh"}}')

    expect(connection.get('advertiser').body['response']).to eq('status' => 'OK')
    expect(connection.token).to eq('fresh')
  end

  describe 'rate limiting' do
    before { allow(connection).to receive(:sleep) }

    it 'waits and retries while the API reports RATE_EXCEEDED' do
      stub_request(:get, "#{uri}advertiser")
        .to_return({ status: 405, headers: json.merge('Retry-After' => '2'), body: rate_exceeded },
                   { status: 200, headers: json, body: '{"response":{"status":"OK"}}' })

      expect(connection.get('advertiser').body['response']).to eq('status' => 'OK')
      expect(connection).to have_received(:sleep).with(2).once
    end

    it 'waits at least a second when Retry-After is not a number of seconds' do
      stub_request(:get, "#{uri}advertiser")
        .to_return({ status: 405, headers: json.merge('Retry-After' => 'Wed, 21 Oct 2026 07:28:00 GMT'),
                     body: rate_exceeded },
                   { status: 200, headers: json, body: '{"response":{"status":"OK"}}' })

      connection.get('advertiser')

      expect(connection).to have_received(:sleep).with(1)
    end

    it 'gives up after MAX_RATE_EXCEEDED_RETRIES' do
      stub_request(:get, "#{uri}advertiser").to_return(status: 405, headers: json, body: rate_exceeded)

      expect { connection.get('advertiser') }.to raise_error(AppnexusApi::RateLimited)
      expect(connection).to have_received(:sleep)
        .exactly(AppnexusApi::Connection::MAX_RATE_EXCEEDED_RETRIES).times
    end
  end
end
