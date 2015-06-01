require "test_helper"
require "proxy/domains"

class DomainsTest < Minitest::Test
  test "domain json validation" do
    domains = Proxy::Domains.new

    assert domains.valid?([["from", "http://to.com"], ["from", "https://to.com"]])
    assert !domains.valid?([["from", "http://to.com"], ["from", "https://to.com", "foo"]])
    assert !domains.valid?([["from", "http://to.com"], [1, "https://to.com"]])
  end

  test "domain format validation" do
    domains = Proxy::Domains.new

    [ # valid
      "http://foo.com",
      "https://foo.com",
      "https://user@foo.com",
      "https://user:pass@foo.com",
      "https://user:pass@foo.com:12345"
    ].each do |domain|
      assert domains.valid_domain?(domain),
             "Domain should be valid: #{domain.inspect}"
    end

    [ # invalid
      "https://foo;bar.com",
      "ht;tps://foo.com",
      "https://foo.com;",
      "other://foo.com",
      "https://foo.com/trailing"
    ].each do |domain|
      assert !domains.valid_domain?(domain),
             "Domain should be invalid: #{domain.inspect}"
    end
  end
end
