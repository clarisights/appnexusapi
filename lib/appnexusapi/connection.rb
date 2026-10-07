require 'appnexusapi/faraday/raise_http_error'
require 'null_logger'

class AppnexusApi::Connection
  attr_reader :token
  attr_accessor :update_token

  RATE_EXCEEDED_DEFAULT_TIMEOUT = 15
  # Inexplicably, sandbox uses the correct code of 429, while production uses 405? so
  # we just rely on the error message
  RATE_EXCEEDED_ERROR = 'RATE_EXCEEDED'.freeze

  def initialize(config)
    @config = config
    @update_token = false
    @config['uri'] ||= 'https://api.appnexus.com/'
    @logger = @config['logger'] || NullLogger.instance
    @token = @config['token']
    @connection = Faraday.new(@config['uri']) do |conn|
      conn.response :logger, @logger, bodies: true
      conn.request :json
      # Registered before :json so it sees the parsed body: response
      # middleware completes from the last registered to the first.
      conn.use AppnexusApi::Faraday::Response::RaiseHttpError
      conn.response :json, :content_type => /\bjson$/
      conn.adapter Faraday.default_adapter
    end 
    update_token_if_expired
  end

  def is_authorized?
    !@token.nil?
  end

  def log
    @logger
  end

  def expired?
    response = @connection.run_request(:get, 'member', {}, { 'Authorization' => @token })
    log.debug(response.body)
    return true if response.body['response']['error_code'] == 'NOAUTH'
  rescue AppnexusApi::Unauthorized
    return true
  end

  def update_token_if_expired
    return if is_authorized? && !expired?
    login
    @update_token = true
  end

  def login
    response = @connection.run_request(:post, 'auth', { 'auth' => { 'username' => @config['username'], 'password' => @config['password'] } }, {})
    log.debug(response.body)
    if response.body['response']['error_code']
      fail "#{response.body['response']['error_code']}/#{response.body['response']['error_description']}"
    end
    @token = response.body['response']['token']
  end

  def logout
    @token = nil
  end

  def get(route, params={}, headers={})
    params = params.delete_if {|key, value| value.nil? }
    run_request(:get, build_url(route, params), nil, headers)
  end

  def build_url(route, params)
    @connection.build_url(route, params)
  end

  def post(route, body=nil, headers={})
    run_request(:post, route, body, headers)
  end

  def put(route, body=nil, headers={})
    run_request(:put, route, body, headers)
  end

  def delete(route, body=nil, headers={})
    run_request(:delete, route, body, headers)
  end

  def run_request(method, route, body, headers)
    update_token_if_expired
    response = {}
    begin
      loop do
        response = run_request_only(
          method,
          route,
          body,
          { 'Authorization' => @token }.merge(headers)
        )
        break if response.body.empty? # Log level data download service returns a body of ""
        break unless response.body.fetch('response', {})['error_code'] == RATE_EXCEEDED_ERROR
        wait_time = response.headers['retry-after'] || RATE_EXCEEDED_DEFAULT_TIMEOUT
        log.info("received rate exceeded.  wait time: #{wait_time}s")
        sleep wait_time.to_i
      end
    rescue AppnexusApi::Unauthorized => e
      if @retry == true
        raise AppnexusApi::Unauthorized, e
      else
        @retry = true
        logout
        response = run_request(method, route, body, headers)
      end
    rescue Faraday::TimeoutError => _e
      raise AppnexusApi::Timeout, 'Timeout'
    ensure
      @retry = false
    end
    log.debug(response.body)
    response
  end

  def run_request_only(method, route, body, headers)
    @connection.run_request(
      method,
      route,
      body,
      { 'Authorization' => @token }.merge(headers)
    )
  end
end
