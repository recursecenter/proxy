require 'net/http'
require 'uri'
require 'json'

module Proxy
  class Domains
    class ParserError < StandardError; end
    class ValidationError < StandardError; end

    def self.fetch
      Domains.new.fetch
    end

    def fetch
      uri = URI.parse(Proxy.config.domains_endpoint)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri.request_uri)
      request.basic_auth('', Proxy.config.domains_secret_token)

      response = http.request(request)

      parse(response.body)
    end

    def parse(json_str)
      json = JSON.parse(json_str)

      unless validate(json)
        raise ValidationError, "invalid domains: #{json}"
      end

      json
    rescue JSON::ParserError => e
      raise ParserError, "invalid json: #{json_str}"
    end

    def validate(domains)
      # [["from", "to"], ["from", "to"], ...]
      domains.is_a?(Array) &&
        domains.all? { |from_to| validate_from_to(from_to) }
    end

    def validate_from_to(from_to)
      from_to.is_a?(Array) &&
        from_to.length == 2 &&
        from_to[0].is_a?(String) &&
        from_to[1].is_a?(String)
    end
  end
end