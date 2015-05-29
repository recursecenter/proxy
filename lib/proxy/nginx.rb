require 'fileutils'

module Proxy
  class Nginx
    CONFIG_LOCATION     = "/etc/nginx/sites-available/default"
    OLD_CONFIG_LOCATION = "/etc/nginx/sites-available/default.old"

    def initialize
      @current_config = nil
    end

    def reload_with_config(nginx_config)
      unless nginx_config == @current_config
        write_config(nginx_config)
        logger.info "Wrote nginx conf; attempting reload"

        if reload
          @current_config = nginx_config
        else
          logger.error "Reload FAILED with invalid nginx conf; reverting to previous"
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
      FileUtils.mv(CONFIG_LOCATION, OLD_CONFIG_LOCATION, force: true)

      File.open(CONFIG_LOCATION, 'w') do |f|
        f.write(nginx_config.to_s)
      end
    end

    def logger
      Proxy.logger
    end
  end
end
