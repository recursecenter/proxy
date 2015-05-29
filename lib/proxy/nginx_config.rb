require 'erb'

module Proxy
  class NginxConfig
    attr_reader :hosts

    ERB_PATH = File.expand_path("../nginx-default.conf.erb", Proxy::ROOT)

    def initialize(hosts)
      @hosts = hosts.sort_by(&:first)
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
  end
end
