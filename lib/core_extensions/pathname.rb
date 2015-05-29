module CoreExtensions
  module Pathname
    # Homebrew inspired hack for pretty-looking paths
    def /(other)
      self + other
    end

    # Backport Ruby 2.1 Pathname#write
    unless respond_to? :write
      def write(s)
        File.open(to_path, "w") do |f|
          f.write(s)
        end
      end
    end
  end
end

require 'pathname'

class Pathname
  include CoreExtensions::Pathname
end
