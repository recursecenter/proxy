require 'logger'
require 'syslog/logger'

module Proxy
  ROOT = File.expand_path(File.dirname(__FILE__))

  require "#{ROOT}/core_extensions/pathname"

  require "#{ROOT}/proxy/nginx"
  require "#{ROOT}/proxy/domains"
  require "#{ROOT}/proxy/nginx_config"

  Config = Struct.new(:env, :domains_endpoint, :domains_secret_token, :delay)

  class << self
    def run
      nginx = Proxy::Nginx.new

      loop do
        nginx_config = Proxy::NginxConfig.new(Proxy::Domains.fetch)
        # nginx_config = Proxy::NginxConfig.new(
        #   [
        #     ["bar", "https://www.google.com"],
        #     ["foo", "https://www.recurse.com"],
        #     ["baz", "https://github.com"]
        #   ]
        # )
        nginx.reload_with_config(nginx_config)
        sleep(config.delay)
      end
    end

    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    def production?
      config.env == "production"
    end

    def logger
      return @logger if defined?(@logger)

      if production?
        @logger = Syslog::Logger.new("proxy")
        @logger.level = Logger::INFO
      else
        @logger = Logger.new(STDOUT)
        @logger.progname = "proxy"
        @logger.level = Logger::DEBUG
      end

      @logger
    end
  end
end
