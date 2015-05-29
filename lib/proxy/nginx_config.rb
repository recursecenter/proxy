require 'erb'
require 'uri'

module Proxy
  class NginxConfig
    attr_reader :domains

    ERB_PATH = File.expand_path("../nginx-default.conf.erb", Proxy::ROOT)

    def initialize(domains)
      @domains = sanitize(domains).sort_by(&:first)
    end

    def domain
      "net.hackerschool.com"
    end

    def contents
      unless defined?(@contents)
        erb = ERB.new(File.read(ERB_PATH))
        @contents = erb.result(binding)
      end

      @contents
    end
    alias to_s contents

    private

    def sanitize(domains)
      domains.map do |from, to|
        [URI.escape(from), URI.escape(to)]
      end
    end
  end
end
