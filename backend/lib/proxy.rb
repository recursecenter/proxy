require 'logger'
require 'syslog/logger'

require_relative "core_extensions/pathname"

module Proxy
  ROOT = File.expand_path(File.dirname(__FILE__))
end

require_relative "proxy/domains"
require_relative "proxy/mapping"
require_relative "proxy/nginx"
require_relative "proxy/nginx_config"

module Proxy
  Config = Struct.new(:env, :domain, :domains_endpoint, :delay)

  class << self
    def run
      nginx = Proxy::Nginx.new
      nginx.wait_for_running

      loop do
        begin
          valid_mappings, invalid_mappings = Proxy::Domains.fetch
          log_invalid_mappings(invalid_mappings)

          nginx_config = Proxy::NginxConfig.new(config.domain, valid_mappings)
          nginx.reload_with_config(nginx_config)

        rescue => e
          log_exception(:error, e)
        end

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

    def https_port
      if production?
        443
      else
        8443
      end
    end

    def logger
      return @logger if defined?(@logger)

      @logger = Syslog::Logger.new("proxy")

      if production?
        @logger.level = Logger::INFO
      else
        @logger.level = Logger::DEBUG
      end

      @logger
    end

    def log_exception(level, e)
      logger.send(level, "#{e.class.name}: #{e.message}")
      e.backtrace.each do |l|
        logger.send(level, l)
      end
    end

    def log_invalid_mappings(mappings)
      mappings.each do |mapping|
        logger.warn("Invalid proxy mapping: #{mapping}")
      end
    end
  end
end
