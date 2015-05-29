require 'logger'
require 'syslog/logger'

module Proxy
  ROOT = File.expand_path(File.dirname(__FILE__))

  require "#{ROOT}/core_extensions/pathname"

  require "#{ROOT}/proxy/cache"
  require "#{ROOT}/proxy/nginx_config"

  Config = Struct.new(:env)

  class << self
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
