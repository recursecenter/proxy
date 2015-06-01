require "minitest/autorun"

class Minitest::Test
  def self.test(name, &block)
    define_method "test_#{name.gsub(/\s+/, "_")}", &block
  end
end
