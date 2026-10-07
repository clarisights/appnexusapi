require 'appnexusapi/faraday/raise_http_error'
require 'null_logger'

class AppnexusApi::Connection
  attr_reader :token
  attr_accessor :update_token

  RATE_EXCEEDED_DEFAULT_TIMEOUT = 15
  # Rate-limited retries of one request before giving up.
  MAX_RATE_EXCEEDED_RETRIES = 20
  # Seconds; overridable with config 'timeout' / 'open_timeout'. Without them
  # a hung request (e.g. under the Typhoeus adapter) never returns.
  DEFAULT_TIMEOUT = 300
  DEFAULT_OPEN_TIMEOUT = 30
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
      conn.options.timeout = @config.fetch('timeout', DEFAULT_TIMEOUT)
      conn.options.open_timeout = @config.fetch('open_timeout', DEFAULT_OPEN_TIMEOUT)
      conn.response :logger, @logger, bodies: true
      conn.request :json
      conn.response :json, :content_type => /\bjson$/
      # Registered after :json, so it runs first on the raw response: an error
      # status is mapped even when the body isn't valid JSON.
      conn.use AppnexusApi::Faraday::Response::RaiseHttpError
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
    response = faraday_request(:get, 'member', {}, { 'Authorization' => @token })
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
    response = faraday_request(:post, 'auth', { 'auth' => { 'username' => @config['username'], 'password' => @config['password'] } }, {})
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
      rate_exceeded = 0
      loop do
        response = run_request_only(
          method,
          route,
          body,
          { 'Authorization' => @token }.merge(headers)
        )
        break unless rate_exceeded?(response.body)

        rate_exceeded += 1
        if rate_exceeded > MAX_RATE_EXCEEDED_RETRIES
          raise AppnexusApi::RateLimited, "#{method.to_s.upcase} #{route}: still rate limited after #{MAX_RATE_EXCEEDED_RETRIES} retries"
        end
        wait_time = response.headers['retry-after'] || RATE_EXCEEDED_DEFAULT_TIMEOUT
        log.info("received rate exceeded.  wait time: #{wait_time}s")
        # An HTTP-date Retry-After becomes 0; never retry without waiting.
        sleep [wait_time.to_i, 1].max
      end
    rescue AppnexusApi::Unauthorized => e
      if @retry == true
        raise AppnexusApi::Unauthorized, e
      else
        @retry = true
        logout
        response = run_request(method, route, body, headers)
      end
    ensure
      @retry = false
    end
    log.debug(response.body)
    response
  end

  def run_request_only(method, route, body, headers)
    faraday_request(
      method,
      route,
      body,
      { 'Authorization' => @token }.merge(headers)
    )
  end

  private

  # The log level data download service returns an empty body; other
  # non-Hash bodies (e.g. text) can't carry an error code either.
  def rate_exceeded?(body)
    body.is_a?(Hash) && body.fetch('response', {})['error_code'] == RATE_EXCEEDED_ERROR
  end

  # Faraday's request, with its transport errors raised as AppnexusApi errors.
  def faraday_request(method, route, body, headers)
    @connection.run_request(method, route, body, headers)
  rescue Faraday::TimeoutError
    raise AppnexusApi::Timeout, 'Timeout'
  rescue Faraday::ParsingError => e
    raise AppnexusApi::InvalidJson, e.message
  rescue Faraday::ConnectionFailed, Faraday::SSLError => e
    raise AppnexusApi::ConnectionFailed, e.message
  end
end
