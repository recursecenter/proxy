#!/bin/bash

set -e # Exit immediately if a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

# To generate HEROKU_API_KEY, run:
# heroku authorizations:create --scope=read,write --description="..."

function heroku_curl() {
    curl --silent --fail \
         --header "Accept: application/vnd.heroku+json; version=3" \
         --header "Authorization: Bearer $HEROKU_API_KEY" \
         "$@"
}

function get_sni_endpoints() {
    heroku_curl "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints"
}

function endpoint_to_update() {
    get_sni_endpoints | jq --raw-output --exit-status ".[] | select(.ssl_cert.cert_domains == [\"*.$DOMAIN\"])"
}

function create_sni_endpoint() {
    local keyfile="$1"
    local certfile="$2"

    heroku_curl --request POST "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints" \
                --header "Content-Type: application/json" \
                --data @<<END
{
    "private_key": "$(cat "$keyfile")",
    "certificate_chain": "$(cat "$certfile")",
}
END
}

function update_sni_endpoint() {
    local id="$1"
    local keyfile="$1"
    local certfile="$2"

    heroku_curl --request PATCH "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints/$id" \
                --header "Content-Type: application/json" \
                --data @<<END
{
    "private_key": "$(cat "$keyfile")",
    "certificate_chain": "$(cat "$certfile")",
}
END
}

function checkenv() {
    local varname="$1"

    if [ -z "${!varname:-}" ]; then
        echo "$varname is not set"
        exit 1
    fi
}

function request_certificate() {
    local keyfile="$1"
    local certfile="$2"

    git clone https://github.com/acmesh-official/acme.sh.git

    ./acme.sh/acme.sh --install --force --nocron --accountemail "$LETS_ENCRYPT_EMAIL"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    ~/.acme.sh/acme.sh --issue -d "*.$DOMAIN" --dns dns_aws --keylength ec-256 --key-file "$keyfile" --fullchain-file "$certfile" --log
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
checkenv HEROKU_API_KEY

keyfile="/tmp/*.$DOMAIN.key"
certfile="/tmp/*.$DOMAIN.crt"

case "$1" in
    issue)
        request_certificate "$keyfile" "$certfile"
        create_sni_endpoint "$keyfile" "$certfile"
        ;;
    renew)
        request_certificate
        update_sni_endpoint "$(endpoint_to_update | jq --raw-output '.id')" "$keyfile" "$certfile"
        ;;
    *)
        echo "Usage: $0 [issue|renew]"
        exit 1
        ;;
esac
