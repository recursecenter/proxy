#!/bin/sh

set -e # Exit immediately if a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

function checkenv() {
    local varname="$1"

    if [ -z "${!varname:-}" ]; then
        echo "$varname is not set"
        exit 1
    fi
}

function request_certificate() {
    git clone https://github.com/acmesh-official/acme.sh.git

    ./acme.sh/acme.sh --install --force --nocron --accountemail "$LETS_ENCRYPT_EMAIL"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    ~/.acme.sh/acme.sh --issue -d "*.$DOMAIN" --dns dns_aws --keylength ec-256 --key-file "/tmp/*.$DOMAIN.key" --fullchain-file "/tmp/*.$DOMAIN.crt" --log
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [issue|renew]"
    exit 1
fi

checkenv DOMAIN
checkenv AWS_ACCESS_KEY_ID
checkenv AWS_SECRET_ACCESS_KEY
checkenv LETS_ENCRYPT_EMAIL
checkenv HEROKU_APP_NAME

case "$1" in
    issue)
        request_certificate
        heroku certs:add "/tmp/*.$DOMAIN.crt" "/tmp/*.$DOMAIN.key" --app "$HEROKU_APP_NAME"
        ;;
    renew)
        request_certificate
        heroku certs:update "/tmp/*.$DOMAIN.crt" "/tmp/*.$DOMAIN.key" --app "$HEROKU_APP_NAME" --confirm "$HEROKU_APP_NAME"
        ;;
    *)
        echo "Usage: $0 [issue|renew]"
        exit 1
        ;;
esac
