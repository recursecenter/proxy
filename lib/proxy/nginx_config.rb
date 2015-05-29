require 'erb'
require 'uri'

module Proxy
  class NginxConfig
    attr_reader :hosts

    ERB_PATH = File.expand_path("../nginx-default.conf.erb", Proxy::ROOT)

    def initialize(hosts)
      @hosts = sanitize(hosts).sort_by(&:first)
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

    def sanitize(hosts)
      hosts.map do |k, v|
        [URI.escape(k), URI.escape(v)]
      end
    end
  end
end
