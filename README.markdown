# Proxy (WIP)

Proxy is a nginx-based reverse proxy with TLS that runs on AWS. It was written to be the backend for a Recurse Center domain service.

Proxy is designed to be a front-end for an unlimited number of webapps all hosted at \*.example.com. For each request, Proxy serves a wildcard TLS certificate for that domain.

## TODO

- System for deploying (zero-downtime deploys, SSL, etc.)
- Zero downtime software updates
- Easy SSL development setup
- In event of broken conf, upload to S3 and include link in error msg
- Pull hosts from a web service
- bin/proxy daemon that polls repeatedly
- A place for config (maybe ENV, maybe elsewhere)
- Make SSL config use current best practices

## Features

- Nightly unattended security updates with zero downtime
- Turnkey deploys with zero downtime
- Dynamic updating of host list from an external HTTPS endpoint
- Secure secret storage with easy secret updating
- Logs to a syslog server (e.g. Papertrail)

## Copyright

Copyright Recurse Center 2015

## License

AGPLv3 or later
