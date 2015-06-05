require 'fileutils'
require 'pathname'

module Proxy
  class Nginx
    CONFIG_LOCATION     = Pathname.new("/etc/nginx/sites-available/default")
    OLD_CONFIG_LOCATION = Pathname.new("/etc/nginx/sites-available/default.old")

    def initialize
      @current_config = nil
    end

    def reload_with_config(nginx_config)
      unless nginx_config == @current_config
        write_config(nginx_config)
        logger.info "Wrote nginx conf, reloading..."

        if reload
          logger.info "Reloaded nginx"
          @current_config = nginx_config
        else
          logger.error "Reload FAILED with invalid nginx conf; reverting to previous"
          logger.error `nginx -t 2>&1`
          revert
        end
      end
    end

    private

    def reload
      system("nginx -t && service nginx reload")
    end

    def revert
      FileUtils.mv(OLD_CONFIG_LOCATION, CONFIG_LOCATION, force: true)
      reload
    end

    def write_config(nginx_config)
      unless CONFIG_LOCATION.exist?
        CONFIG_LOCATION.write(Proxy::NullConfig.new.to_s)
      end

      FileUtils.mv(CONFIG_LOCATION, OLD_CONFIG_LOCATION, force: true)

      CONFIG_LOCATION.write(nginx_config.to_s)
    end

    def logger
      Proxy.logger
    end
  end
end
