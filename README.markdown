# Proxy (WIP)

Proxy is a nginx-based reverse proxy with TLS that runs on AWS. It was written to be the backend for a Recurse Center domain service.

Proxy is designed to be a front-end for an unlimited number of webapps all hosted at \*.example.com. For each request, Proxy serves a wildcard TLS certificate for that domain.

## TODO

- TLS session resumption
- Env var for syslog drain
- WebSocket support (see http://nginx.com/blog/websocket-nginx/)
- Config stored in the cloud to support multiple people deploying
  - In event of broken conf, upload to S3 and include link in error msg
  - Easy SSL development setup

## Features

- Nightly unattended security updates with zero downtime
- Easy deploys with near-zero downtime
- Dynamic updating of host list from an external HTTPS endpoint
- Secure secret storage with easy secret updating
- Logs to a syslog server (e.g. Papertrail)

## Example config.production.yml

```yml
aws:
  elb_name: proxy-elb
  region: us-east-1
  ami: ami-d05e75b8 # Ubuntu 14.04 for us-east-1
  instance_type: m3.medium
  instance_count: 2
  key_name: Zach
  security_group: proxy
env:
  PROXY_ENV: production
  PROXY_DOMAIN: recurse.com
  PROXY_DOMAINS_ENDPOINT: https://www.recurse.com/api/public/domains
```

## Copyright

Copyright Recurse Center 2015

## License

AGPLv3 or later
