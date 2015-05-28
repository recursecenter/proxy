# Proxy

Proxy is a nginx-based reverse proxy with TLS that runs on AWS. It was written to be the backend for a Recurse Center domain service.

Proxy is designed to be a front-end for an unlimited number of webapps all hosted at \*.example.com. For each request, Proxy serves a wildcard TLS certificate for that domain.

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
