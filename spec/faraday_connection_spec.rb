require 'spec_helper'

# What AppnexusApi::Connection gets from Faraday: JSON in and out, HTTP errors
# raised as AppnexusApi errors, timeouts as AppnexusApi::Timeout.
describe AppnexusApi::Connection, 'over Faraday' do
  include WebMock::API

  let(:uri) { 'https://api.example.test/' }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:connection) { AppnexusApi::Connection.new('uri' => uri, 'token' => 'tok') }

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    stub_request(:get, "#{uri}member")
      .to_return(status: 200, headers: json, body: '{"response":{"status":"OK"}}')
  end

  after { WebMock.reset! }

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

  it 'raises NotFound with the API errors in the message' do
    stub_request(:get, "#{uri}advertiser")
      .to_return(status: 404, headers: json, body: '{"errors":["no such advertiser"]}')

    expect { connection.get('advertiser') }
      .to raise_error(AppnexusApi::NotFound, /404\nno such advertiser/)
  end

  # On Faraday 1.10 the rescue for Faraday::Error::TimeoutError (a constant
  # that no longer existed) turned every such error into a NameError.
  it 'raises InternalServerError on a 500' do
    stub_request(:get, "#{uri}advertiser").to_return(status: 500, headers: json, body: '{}')

    expect { connection.get('advertiser') }.to raise_error(AppnexusApi::InternalServerError)
  end

  it 'raises AppnexusApi::Timeout when the response times out' do
    stub_request(:get, "#{uri}advertiser").to_raise(Net::ReadTimeout)

    expect { connection.get('advertiser') }.to raise_error(AppnexusApi::Timeout)
  end
end
