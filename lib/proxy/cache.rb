require 'digest'

module Proxy
  class Cache
    CACHE_DIR = Pathname.new(File.expand_path("../cache", Proxy::ROOT))

    def initialize
      CACHE_DIR.mkpath
    end

    def include?(obj)
      (CACHE_DIR/filename(obj.to_s)).exist?
    end

    def store(obj)
      s = obj.to_s

      write(s) unless include?(s)
    end

    def path(obj)
      path_name(obj.to_s).to_s
    end

    private

    def path_name(s)
      CACHE_DIR/filename(s)
    end

    def write(s)
      path = path_name(s)
      path.write(s)

      path.to_s
    end

    def filename(s)
      digest(s)
    end

    def digest(s)
      Digest::SHA256.hexdigest(s)
    end
  end
end
