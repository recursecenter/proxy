require "test_helper"
require "proxy/domains"

class DomainsTest < Minitest::Test
  test "domain json validation" do
    domains = Proxy::Domains.new

    assert domains.valid_json?([["from", "http://to.com"], ["from", "https://to.com"]])
    assert !domains.valid_json?([["from", "http://to.com"], ["from", "https://to.com", "foo"]])
    assert !domains.valid_json?([["from", "http://to.com"], [1, "https://to.com"]])
  end
end
