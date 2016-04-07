require "test_helper"
require "proxy/mapping"

class MappingTest < MiniTest::Test
  test "url format validation" do
    [ # valid
      "http://foo.com",
      "https://foo.com",
      "https://user@foo.com",
      "https://user:pass@foo.com",
      "https://user:pass@foo.com:12345",
      "https://foo.com/trailing",
      "https://foo.com/",
      "https://foo.com/trailing/",
    ].each do |url|
      assert Proxy::Mapping.new(["foo", url]).valid_url?,
             "URL should be valid: #{url.inspect}"
    end

    [ # invalid
      "https://foo;bar.com",
      "ht;tps://foo.com",
      "https://foo.com;",
      "other://foo.com",
      "https://foo.com'return",
      "https://user'return:pass@foo.com",
      "https://user:pass'return@foo.com"
    ].each do |url|
      assert !Proxy::Mapping.new(["foo", url]).valid_url?,
             "URL should be invalid: #{url.inspect}"
    end
  end

  test "subdomain format validation" do
    [ # valid
      "aB-cD123",
      "a"
    ].each do |subdomain|
      assert Proxy::Mapping.new([subdomain, "https://example.com"]).valid_subdomain?,
             "Subdomain should be valid: #{subdomain.inspect}"
    end


    [ # invalid
      "foo.bar",
      "-foo",
      "foo-",
      "foo;bar",
      "foo$bar",
      ""
    ].each do |subdomain|
      assert !Proxy::Mapping.new([subdomain, "https://example.com"]).valid_subdomain?,
             "Subdomain should be invalid: #{subdomain.inspect}"
    end
  end

  test "url escaping" do
    {
      "https://foo:pa$$word@foo.com/" => "'https://foo:pa\\$\\$word@foo.com/'"
    }.each do |from, to|
      assert_equal Proxy::Mapping.new(["foo", from]).url, to
    end
  end

  test "adds trailing slas" do
    {
      "https://www.example.com/foo" => "https://www.example.com/foo/",
      "https://www.example.com/foo/" => "https://www.example.com/foo/",
      "https://www.example.com" => "https://www.example.com/",
      "https://www.example.com/" => "https://www.example.com/",
    }.each do |from, to|
      assert_equal Proxy::Mapping.new(["foo", from]).original_url, to
    end
  end
end
