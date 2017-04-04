require 'erb'
require 'uri'
require 'digest'

module Proxy
  class NginxConfig
    attr_reader :domain, :mappings, :apex_domains

    ERB_PATH = File.expand_path("../root/etc/nginx/sites-available/default.erb", Proxy::ROOT)

    def initialize(domain, mappings, apex_domains)
      @domain = domain
      @mappings = mappings.sort_by(&:subdomain)
      @apex_domains = apex_domains
    end

    def contents
      unless defined?(@contents)
        erb = ERB.new(File.read(ERB_PATH))
        @contents = erb.result(binding)
      end

      @contents
    end
    alias to_s contents

    def digest
      @digest ||= Digest::SHA256.hexdigest(contents)
    end

    def ==(other)
      if other.is_a?(NginxConfig)
        digest == other.digest
      else
        false
      end
    end
  end

  class NullConfig < NginxConfig
    def initialize; end

    def mappings
      []
    end
  end
end
