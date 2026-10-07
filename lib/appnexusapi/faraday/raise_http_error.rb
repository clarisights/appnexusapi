require 'json'

module AppnexusApi
  module Faraday
    module Response
      # Raises an AppnexusApi error for an HTTP error status. It runs before the
      # :json response middleware, so it reads the raw body itself.
      class RaiseHttpError < ::Faraday::Middleware
        ERRORS = {
          400 => AppnexusApi::BadRequest,
          401 => AppnexusApi::Unauthorized,
          403 => AppnexusApi::Forbidden,
          404 => AppnexusApi::NotFound,
          406 => AppnexusApi::NotAcceptable,
          422 => AppnexusApi::UnprocessableEntity,
          500 => AppnexusApi::InternalServerError,
          501 => AppnexusApi::NotImplemented,
          502 => AppnexusApi::BadGateway,
          503 => AppnexusApi::ServiceUnavailable
        }.freeze
        # Production signals rate limiting with 405 (sandbox with 429) and a
        # RATE_EXCEEDED error_code; Connection#run_request waits and retries.
        RATE_LIMIT_STATUSES = [405, 429].freeze

        def on_complete(response)
          status = response[:status].to_i
          error = ERRORS.fetch(status) do
            AppnexusApi::Error if status >= 400 && !RATE_LIMIT_STATUSES.include?(status)
          end
          raise error, error_message(response) if error
        end

        def error_message(response)
          msg = "#{response[:method].to_s.upcase} #{response[:url]}: #{response[:status]}"
          details = error_details(parsed_body(response[:body]))
          msg << "\n" << details.join("\n") if details.any?
          msg
        end

        private

        # AppNexus reports errors as {"response": {"error_id", "error_code", "error"}}.
        def error_details(body)
          return [] unless body.is_a?(Hash)

          api = body['response'].is_a?(Hash) ? body['response'] : {}
          Array(body['errors']) + api.values_at('error_id', 'error_code', 'error').compact
        end

        def parsed_body(body)
          return body unless body.is_a?(String)

          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
