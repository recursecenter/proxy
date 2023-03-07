#!/bin/bash

set -e # Exit immediately if a command fails
set -E # Trigger the ERR trap when a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

# Requires heroku-community/apt buildpack with the following Aptfile:
#   jq
#   awscli

# To generate HEROKU_API_KEY, run:
#   heroku authorizations:create --scope=read,write --description="..."

# To set automatically set the HEROKU_APP_NAME config var, run:
#   heroku labs:enable runtime-dyno-metadata

function heroku_curl() {
    curl --silent --fail-with-body \
         --header "Accept: application/vnd.heroku+json; version=3" \
         --header "Authorization: Bearer $HEROKU_API_KEY" \
         "$@"
}

function get_domain() {
    local domain="$1"

    heroku_curl "https://api.heroku.com/apps/$HEROKU_APP_NAME/domains/$domain"
}

function endpoint_id_to_update() {
    local domain="$1"

    local id="$(get_domain "$domain" | jq --raw-output '.sni_endpoint | .id')"

    if [ "$id" = "null" ]; then
        id=""        
    fi

    echo "$id"
}

function escape_newlines() {
    awk '{ printf "%s\\n", $0 }'
}

function create_sni_endpoint() {
    local certfile="$1"
    local keyfile="$2"

    heroku_curl --request POST "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints" \
                --header "Content-Type: application/json" \
                --data @<(cat <<END
{
    "certificate_chain": "$(cat "$certfile" | escape_newlines)",
    "private_key": "$(cat "$keyfile" | escape_newlines)"
}
END
)
}

function update_sni_endpoint() {
    local id="$1"
    local certfile="$2"
    local keyfile="$3"

    heroku_curl --request PATCH "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints/$id" \
                --header "Content-Type: application/json" \
                --data @<(cat <<END
{
    "certificate_chain": "$(cat "$certfile" | escape_newlines)",
    "private_key": "$(cat "$keyfile" | escape_newlines)"
}
END
)
}

function attach_sni_endpoint() {
    local id="$1"
    local domain="$2"

    heroku_curl --request PATCH "https://api.heroku.com/apps/$HEROKU_APP_NAME/domains/$domain" \
                --header "Content-Type: application/json" \
                --data @<(cat <<END
{
    "sni_endpoint": "$id"
}
END
)
}

function checkenv() {
    local varname="$1"

    if [ -z "${!varname:-}" ]; then
        echo "$varname is not set"
        exit 1
    fi
}

function install_acme_sh() {
    local email="$1"

    git clone https://github.com/acmesh-official/acme.sh.git

    pushd acme.sh > /dev/null
    ./acme.sh --install --force --nocron --accountemail "$email"
    popd > /dev/null 

    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
}

function upgrade_acme_sh() {
    "$HOME/.acme.sh/acme.sh" --upgrade
}

function issue_certificate() {
    local domain="$1"
    local certfile="$2"
    local keyfile="$3"
    local flags="$4"

    "$HOME/.acme.sh/acme.sh" --issue --domain "$domain" --dns dns_aws --keylength ec-256 --key-file "$keyfile" --fullchain-file "$certfile" --log "$flags"
}

function renew_certificates_if_necessary() {
    local flags="$1"

    "$HOME/.acme.sh/acme.sh" --cron --log "$flags"
}

function s3_url() {
    local bucket="$1"
    local filename="$2"

    echo "s3://$bucket/$filename"
}

function s3_object_exists() {
    local bucket="$1"
    local filename="$2"

    aws s3 ls $(s3_url "$bucket" "$filename") > /dev/null 2>&1
}

function save_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    tar -czf "$cachefile" -C "$(dirname "$cachedir")" "$(basename "$cachedir")"
    aws s3 cp "$cachefile" $(s3_url "$bucket" "$cachefile")
}

function restore_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    if ! s3_object_exists "$bucket" "$cachefile"; then
        return
    fi

    aws s3 cp $(s3_url "$bucket" "$cachefile") "$cachefile"
    tar -xzf "$cachefile" -C $(dirname "$cachedir")
}


staging=false

if [ "$1" = "--staging" ]; then
    staging=true
    shift
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [--staging] <issue|clear-cache>"
    exit 1
fi

checkenv DOMAIN
checkenv AWS_ACCESS_KEY_ID
checkenv AWS_SECRET_ACCESS_KEY
checkenv AWS_DEFAULT_REGION
checkenv CERTS_BUCKET
checkenv LETS_ENCRYPT_EMAIL
checkenv HEROKU_APP_NAME
checkenv HEROKU_API_KEY

wildcard="*.$DOMAIN"

keyfile="/tmp/$wildcard.key"
certfile="/tmp/$wildcard.crt"

cachedir="$HOME/.acme.sh"

if [ "$staging" = true ]; then
    acmeflags="--staging"
    cachefile="${HEROKU_APP_NAME}.staging.tar.gz"
else
    acmeflags=""
    cachefile="${HEROKU_APP_NAME}.tar.gz"
fi

# We test for the existence of the certificate file to determine if the certificates
# needed to be renewed. Delete them here so that we don't accidentally think the certs
# have been renewed when they haven't. This matters in development – on Heroku, the
# filesystem is ephemeral, so this is a no-op.
rm -f "$keyfile" "$certfile"

trap "echo 'error: \"$0 $1\" failed'" ERR

case "$1" in
    issue)
        restore_cache "$CERTS_BUCKET" "$cachefile" "$cachedir"

        if [ -d "$cachedir" ]; then
            upgrade_acme_sh
            renew_certificates_if_necessary "$acmeflags"
        else
            install_acme_sh "$LETS_ENCRYPT_EMAIL"
            issue_certificate "$wildcard" "$certfile" "$keyfile" "$acmeflags"
        fi

        # If the certificate file doesn't exist, then the certificates didn't need to be renewed.
        if [ ! -f "$certfile" ]; then
            save_cache "$CERTS_BUCKET" "$cachefile" "$cachedir"
            echo "Certificates are up to date"
            exit 0
        fi

        endpoint_id=$(endpoint_id_to_update "$wildcard")

        if [ -n "$endpoint_id" ]; then
            update_sni_endpoint "$endpoint_id" "$certfile" "$keyfile" > /dev/null
        else
            endpoint_id=$(create_sni_endpoint "$certfile" "$keyfile" | jq --raw-output '.id')
            attach_sni_endpoint "$endpoint_id" "$wildcard" > /dev/null
        fi

        save_cache "$CERTS_BUCKET" "$cachefile" "$cachedir"
        ;;
    clear-cache)
        aws s3 rm $(s3_url "$CERTS_BUCKET" "$cachefile")
        ;;
    *)
        echo "Usage: $0 [--staging] <issue|clear-cache>"
        exit 1
        ;;
esac
