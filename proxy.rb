require "bundler/setup"

require "dotenv/load"
require "async"
require "async/http"
require "concurrent-ruby"
require "rack"

require "logger"
require "net/http"
require "uri"

log = Logger.new(STDOUT)

log.info "Proxy starting..."

port = Integer(ENV["PORT"] || 80)
domain = ENV.fetch("DOMAIN")
api_endpoint = ENV.fetch("ENDPOINT")

read_timeout = Integer(ENV["READ_TIMEOUT"] || 5)
write_timeout = Integer(ENV["WRITE_TIMEOUT"] || 10)
refresh_interval = Integer(ENV["REFRESH_INTERVAL"] || 5)

if read_timeout < 1
  log.fatal "error: READ_TIMEOUT must be greater than 0"
  exit 1
elsif write_timeout < 1
  log.fatal "error: WRITE_TIMEOUT must be greater than 0"
  exit 1
elsif refresh_interval < 1
  log.fatal "error: REFRESH_INTERVAL must be greater than 0"
  exit 1
end

log.info "*     read timeout: #{read_timeout}"
log.info "*    write timeout: #{write_timeout}"
log.info "* refresh interval: #{refresh_interval}"
log.info "*           domain: #{domain}"
log.info "*         endpoint: #{api_endpoint}"
log.info "* Listening on http://0.0.0.0:#{port}"
log.info "* Listening on http://[::]:#{port}"

mapping = Concurrent::Hash.new

# Binding to the IPv6 any address (::) allows us to accept IPv4 connections
# on the same socket. The remote_address of the accepted connection will be
# an IPv4-mapped IPv6 address (e.g. "::ffff:8.8.8.8").
listen_endpoint = Async::HTTP::Endpoint.parse("http://[::]:#{port}", timeout: read_timeout)

def proxy(request, mapping, domain, log)
  host = request.authority

  if host.nil?
    log.error "[] #{request.method} #{request.path}; error: no host header"
    return Protocol::HTTP::Response[502, {}, ["502 Bad Gateway\n"]]
  end

  subdomain = host.split(".").first    

  if subdomain.nil? || host != subdomain + "." + domain
    log.error "[#{host}] #{request.method} #{request.path}; error: invalid host: \"#{host}\" must be a subdomain of \"#{domain}\""
    return Protocol::HTTP::Response[502, {}, ["502 Bad Gateway\n"]]
  end

  target = mapping[subdomain]

  if target.nil?
    log.error "[#{host}] #{request.method} #{request.path}; error: unknown host #{host}"
    return Protocol::HTTP::Response[404, {}, ["404 Not Found\n"]]
  end

  target = 'http://localhost:9292'
  endpoint = nil
  begin
    endpoint = Async::HTTP::Endpoint.parse(target)
  rescue => e
    log.error "[#{host}] #{request.method} #{request.path}; error: invalid target: #{e.message}"
    return Protocol::HTTP::Response[502, {}, ["502 Bad Gateway\n"]]
  end

  # At this point, we're confident that we can forward, so prepare the proxy request.
  proxy_req = Async::HTTP::Protocol::Request[request.method, endpoint.path.chomp("/") + request.path, request.headers.dup, request.body]

  # IPv4 connections come in as IPv4-mapped IPv6 addresses (e.g. "::ffff:8.8.8.8").
  addr = request.remote_address
  if addr.ipv6_v4mapped?
    addr = addr.ipv6_to_ipv4
  end

  quoted_addr = addr.ip_address
  if addr.ipv6?
    quoted_addr = "\"[#{quoted_addr}]\""
  end

  # Headers#[] will merge headers with the same name in an appropriate way. For example,
  # X-Forwarded-For will be joined with a comma to the existing value. Headers#set will
  # delete any existing value and set the new one.
  #
  # We want to append to X-Forwarded-For, and Forwarded, and replace X-Forwarded-Host
  # and X-Forwarded-Proto.
  #
  # It seems you must specify the header name in lowercase or weird things happen.
  proxy_req.headers["x-forwarded-for"] = quoted_addr
  proxy_req.headers.set('x-forwarded-host', host)
  # We only listen on HTTP, so we can hardcode this. We expect to be run behind another
  # reverse proxy that terminates TLS.
  proxy_req.headers.set('x-forwarded-proto', "http")

  proxy_req.headers['forwarded'] = "for=#{quoted_addr};host=#{host};proto=http"

  client = Async::HTTP::Client.new(endpoint)

  response = client.call(proxy_req)
  response.headers.set("server", "Proxy/2.0")

  log.info "[#{host}] #{request.method} #{request.path} -> #{target}; #{response.status} #{Rack::Utils::HTTP_STATUS_CODES[response.status]}"

  response
end

Async do |task|
  trap :INT do
    puts "Shutting down..."
    task.stop
  end

  trap :TERM do
    puts "Shutting down..."
    task.stop
  end

  Async do
    loop do
      begin
        body = Net::HTTP.get(URI.parse(api_endpoint))

        # The schema is an array of arrays. Each inner array has two elements, both of them are strings.
        m = JSON.parse(body).to_h

        mapping.replace(m)
      rescue => e
        log.error "error: couldn't fetch domains: #{e.message}"
      ensure
        sleep refresh_interval
      end
    end
  end

  Async do
    server = Async::HTTP::Server.for(listen_endpoint) do |request|
      proxy(request, mapping, domain, log)
    rescue Async::TimeoutError => e
      # write timeout
      log.error "[#{request.authority}] #{request.method} #{request.path} error: write timeout: #{e.message}"
      Protocol::HTTP::Response[504, {}, ["504 Gateway Timeout\n"]]
    rescue => e
      log.error "[#{request.authority}] #{request.method} #{request.path} error: unexpected exception: #{e.class}: #{e.message}"
      e.backtrace.each do |line|
        log.error line
      end
    
      Protocol::HTTP::Response[500, {}, ["500 Internal Server Error\n"]]
    end
  
    begin
      server.run
    rescue => e
      log.error "error: timeout?!"
    end
  rescue Async::TimeoutError => e
    # read timeout
    log.error "error: read timeout: #{e.message}"
  end
end

log.info "Proxy stopped"
