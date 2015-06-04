module Proxy
  class Mapping
    attr_reader :subdomain, :url, :original_url

    def initialize(from_to)
      @subdomain = from_to[0]
      @original_url = from_to[1]
      @url = escape_url(from_to[1])
    end

    def valid?
      valid_subdomain? && valid_url?
    end

    def valid_subdomain?
      if subdomain[0] == '-' || subdomain[-1] == '-'
        return false
      end

      !!subdomain.match(/\A[a-zA-Z0-9-]+\z/)
    end

    def valid_url?
      uri = URI.parse(original_url)

      ["http", "https"].include?(uri.scheme) &&
        uri.path.empty?
    rescue URI::InvalidURIError => e
      false
    end

    def to_s
      "#{subdomain} -> #{original_url}"
    end

    def inspect
      "#<Mapping #{to_s}>"
    end

    private

    def escape_url(url)
      "'#{url.gsub(/\$/, '\$')}'"
    end
  end
end
