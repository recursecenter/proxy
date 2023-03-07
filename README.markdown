# Proxy

Proxy is an HTTP reverse proxy. It was written to be the backend for the Recurse Center custom subdomain service, which lets RC alumni register a recurse.com subdomain for their webapp or website.

Proxy handles requests for subdomains of a single domain. It periodically loads a JSON endpoint continaing mappings from subdomain to URL, and then proxies requests to each subdomain to the appropriate URL.

Proxy can be run almost anywhere, including Heroku.

For simplicity, Proxy handles HTTP requests only. You should deploy it behind a TLS-terminating load balancer on a secure network like a VPC. There is an included certs.sh script that can provision a wildcard certificate from Let's Encrypt and install it on Heroku. See the source of certs.sh for detailed setup instructions.

## Dependencies

- Go
- curl, jq, and openssl (for certs.sh)

## Setup

Proxy gets its configuration from environmental variables:

| Variable | Example | Description | Required | Default |
| --- | --- | --- | --- | --- |
| `DOMAIN` | example.com | The domain to handle requests for. | **Yes** | |
| `ENDPOINT` | https://www.example.com/domains.json | The URL of the JSON endpoint containing mappings from subdomain to URL. | **Yes** | |
| `PORT` | 8080 | The port that Proxy should listen on. | No | 80 |
| `READ_TIMEOUT` | 10 | Maximum number of seconds Proxy waits to read a request from a client. | No | 5 |
| `WRITE_TIMEOUT` | 15 | Maximum number of seconds Proxy will spend writing a response to the client before timing out. This includes time spend proxying the request. | No | 10 |
| `SHUTDOWN_TIMEOUT` | 20 | Maximum number of seconds Proxy will wait for in-flight requests to complete while shutting down. After this duration has expired, Proxy will kill all inflight requests. | No | 10 |
| `REFRESH_INTERVAL` | 10 | Proxy fetches `$ENDPOINT` every `$REFRESH_INTERVAL` seconds. | No | 5 |

## Running

Proxy runs in the foreground and logs to STDOUT. All error messages contain the string "error:". When it receives a SIGINT or a SIGTERM, Proxy shuts down.

If present, Proxy will read its configuration out of a `.env` file. Here's a starting point for development:

```dotenv
DOMAIN=example.com
ENDPOINT=https://www.example.com/domains.json
```

To start Proxy locally, run:

```shell
$ go run .
```

You can use `curl` to make a request to a mapped subdomain:

```shell
$ curl --header 'Host: foo.example.com' http://localhost
```

## Subdomain mappings endpoint

In order to use Proxy, you need a publicly accessible HTTP endpoint that returns a set of mappings from subdomain to URL. The endpoint must return JSON data in the following format:

```
[
  ["subdomain1", "https://www.example.com/foo"],
  ["subdomain2", "https://www.example.net"],
  ["subdomain3", "http://www.example.org"]
]
```

## Copyright

Copyright Recurse Center.

## License

This project is licensed under the terms of the BSD 2-clause "Simplified" license. See LICENSE.md for full terms.
