module Proxy
  class Mapping
    attr_reader :subdomain, :url, :original_url

    def initialize(from_to)
      @subdomain = from_to[0]
      @original_url = ensure_trailing_slash(from_to[1])
      @url = escape_url(@original_url)
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
        !original_url.include?("'")
    rescue URI::InvalidURIError
      false
    end

    def to_s
      "#{subdomain} -> #{original_url}"
    end

    def inspect
      "#<Mapping #{to_s}>"
    end

    private

    def ensure_trailing_slash(s)
      u = URI.parse(s)

      if u.path != "" && !u.path.end_with?("/")
        u.path += "/"
      end

      u.to_s
    rescue URI::InvalidURIError
      s
    end

    def escape_url(url)
      "'#{url.gsub(/\$/, '\$')}'"
    end
  end
end
