#!/bin/sh

set -e # Exit immediately if a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

if [ "$(date +%u)" -eq 1 ]; then
    ./certs.sh renew
fi
