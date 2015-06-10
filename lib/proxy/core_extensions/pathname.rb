require 'pathname'

class Pathname
  # Homebrew inspired hack for pretty-looking paths
  alias / +

  # Backport Ruby 2.1 Pathname#write
  unless method_defined?(:write)
    def write(s)
      File.open(to_path, "w") do |f|
        f.write(s)
      end
    end
  end
end
