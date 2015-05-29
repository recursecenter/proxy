require 'logger'
require 'syslog/logger'

module Proxy
  ROOT = File.expand_path(File.dirname(__FILE__))

  require "#{ROOT}/core_extensions/pathname"

  require "#{ROOT}/proxy/cache"
  require "#{ROOT}/proxy/nginx_config"

  class << self
    def production?
      false
    end

    def development?
      true
    end

    def logger
      return @logger if defined?(@logger)

      if Proxy.production?
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
