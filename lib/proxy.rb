module Proxy
  ROOT = File.expand_path(File.dirname(__FILE__))

  require "#{ROOT}/core_extensions/pathname"

  require "#{ROOT}/proxy/nginx_config"
  require "#{ROOT}/proxy/cache"
end
