#!/bin/bash

# Wildcard certificates from Let's Encrypt for Heroku apps
#
# How it works:
#
#  `certs.sh issue` generates or renews certificates for a set of domains using
#  Let's Encrypt, and installs them on Heroku. Crucially, it supports wildcard
#  domains. The first domain specified is the primary domain. Certs.sh uses it
#  to determine which of HEROKU_APP_NAME's domains to install the certificate on.
#
#  Certs.sh uses acme.sh with the dns_aws dnsapi provider to satisfy the DNS-01 challenge.
#
#  The --staging flag can be used to target Let's Encrypt's staging server. Use this if
#  you're testing changes to this script.
#
#  Acme.sh state is cached encrypted in S3. This means you can run `certs.sh issue`
#  as many times as you want. The certificate will only be renewed if it's nearing
#  its expiration. Use Heroku Scheduler to run `certs.sh issue` daily.
#
#  If you use certs.sh to issue a wildcard certificate, make sure to put the wildcard
#  domain in quotes (e.g. certs.sh issue "*.example.com"). Otherwise you might have
#  shell globbing issues.
#
#  Acme.sh state is cached by app name ($HEROKU_APP_NAME.tar.gz), so multiple apps can
#  use the same bucket to cache their state. Staging state is cached
#  separately ($HEROKU_APP_NAME.staging.tar.gz).
#
#  `certs.sh clear-cache` deletes the acme.sh state from S3. Remember to use --staging
#  if you want to clear the staging cache while you're modifying this script.
#
# External services:
#  - Heroku
#  - Amazon S3
#  - Amazon Route 53
#  - Let's Encrypt
#
# Dependencies:
#  - curl (comes pre-installed on Heroku)
#  - openssl (ditto)
#  - awk (ditto)
#  - sed (ditto)
#  - bash (ditto)
#  - jq and libjq1 (use the heroku-community/apt buildpack with "jq" in your Aptfile)
#  - acme.sh (installed and managed by this script)
#
# Heroku-buildpack-apt notes:
#
#  The jq package depends on libjq1, but if your Aptfile contains the only the former,
#  the latter won't be installed. I'm not sure why this is, but adding libjq1 to the
#  Aptfile explicitly fixed the problem.
#
# Environmental variables:
#  - HEROKU_APP_NAME
#  - HEROKU_API_KEY
#  - AWS_ACCESS_KEY_ID
#  - AWS_SECRET_ACCESS_KEY
#  - AWS_DEFAULT_REGION
#  - LETS_ENCRYPT_EMAIL
#  - CERTS_BUCKET
#
# Required AWS IAM permissions:
#  - s3:PutObject
#  - s3:GetObject
#  - s3:DeleteObject
#  - route53:GetHostedZone
#  - route53:ListResourceRecordSets
#  - route53:ChangeResourceRecordSets
#  - route53:ListHostedZones
#  - route53:GetHostedZoneCount
#  - route53:ListHostedZonesByName
#
# Setup:
#  - Generate a Heroku API key with read/write access, and set it as HEROKU_API_KEY:
#    heroku config:set HEROKU_API_KEY=$(heroku authorizations:create --short --scope=read,write --description="...")
#
#  - Enable runtime-dyno-metadata to automatically set HEROKU_APP_NAME:
#    heroku labs:enable runtime-dyno-metadata
#
#  - Create a bucket on S3 with no public permissions, and set CERTS_BUCKET to its name. Make sure
#    it uses server-side encryption with S3 managed keys (SSE-S3). This is the default as of March 2023.
#
#  - Create a Route 53 IAM polcy (substitute $ZONE_ID):
#    {
#        "Version": "2012-10-17",
#        "Statement": [
#            {
#                "Sid": "VisualEditor0",
#                "Effect": "Allow",
#                "Action": [
#                    "route53:GetHostedZone",
#                    "route53:ChangeResourceRecordSets",
#                    "route53:ListResourceRecordSets"
#                ],
#                "Resource": "arn:aws:route53:::hostedzone/$ZONE_ID"
#            },
#            {
#                "Sid": "VisualEditor1",
#                "Effect": "Allow",
#                "Action": [
#                    "route53:ListHostedZones",
#                    "route53:GetHostedZoneCount",
#                    "route53:ListHostedZonesByName"
#                ],
#                "Resource": "*"
#            }
#        ]
#    }
#
#  - Create a S3 IAM policy (substitute $BUCKET_NAME):
#    {
#        "Version": "2012-10-17",
#        "Statement": [
#            {
#                "Sid": "VisualEditor0",
#                "Effect": "Allow",
#                "Action": [
#                    "s3:PutObject",
#                    "s3:GetObject",
#                    "s3:DeleteObject"
#                ],
#                "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
#            }
#        ]
#    }
#
#  - Create an IAM user with the above policies, and set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
#  - Set AWS_DEFAULT_REGION to the region of your S3 bucket.
#  - Set LETS_ENCRYPT_EMAIL to the address you want to receive Let's Encrypt emails.
#  - Set DOMAIN to the domain you want to issue a certificate for (e.g. "example.com")
#  - Deploy the app
#  - Run `heroku run ./certs.sh issue` to generate a certificate.
#  - Set up Heroku Scheduler to run `./certs.sh renew` daily.

set -e # Exit immediately if a command fails
set -E # Trigger the ERR trap when a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

## S3

# AWS specific url-encoding rules

function urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [A-Za-z0-9-._~] ) encoded="$encoded$c" ;;
            * )               encoded="$encoded%"$(printf "%02X" "'$c") ;;
        esac
    done

    echo -n "$encoded"
}

function urlencode_path() {
    urlencode "$1" | sed 's/%2F/\//g'
}

# `openssl dgst` has different output on macOS (LibreSSL) and Linux (OpenSSL):
# macOS: abc123
# Linux: SHA256(stdin)= abc123
#
# This function extracts the last field of the output, which is the hexdigest on both platforms.
function last_field() {
    awk '{ print $NF }'
}

function sha256 {
    openssl dgst -sha256 | last_field
}

function hmac_sha256 {
    local key="$1"

    openssl dgst -sha256 -mac HMAC -macopt "$key" | last_field
}

function aws_authorization_header() {
    local method="$1"
    local region="$2"
    local service="$3"
    local host="$4"
    local canonical_uri="$5"
    local canonical_querystring="$6"
    local timestamp="$7"
    local hexdigest="$8"

    local datestamp=$(echo -n "$timestamp" | cut -c 1-8)
    local signed_headers="host;x-amz-content-sha256;x-amz-date"

    local scope="$datestamp/$region/$service/aws4_request"

    local canonical_request="$method
$(urlencode_path "$canonical_uri")
$(urlencode "$canonical_querystring")
host:$host
x-amz-content-sha256:$(echo -n "$hexdigest")
x-amz-date:$timestamp

$signed_headers
$hexdigest"

    local string_to_sign="AWS4-HMAC-SHA256
$timestamp
$scope
$(echo -n "$canonical_request" | sha256)"

    local date_key=$(echo -n "$datestamp" | hmac_sha256 key:"AWS4$AWS_SECRET_ACCESS_KEY")
    local date_region_key=$(echo -n "$region" | hmac_sha256 hexkey:"$date_key")
    local date_region_service_key=$(echo -n "$service" | hmac_sha256 hexkey:"$date_region_key")
    local signing_key=$(echo -n "aws4_request" | hmac_sha256 hexkey:"$date_region_service_key")

    local signature=$(echo -n "$string_to_sign" | hmac_sha256 hexkey:"$signing_key")

    echo "Authorization: AWS4-HMAC-SHA256 Credential=$AWS_ACCESS_KEY_ID/$scope,SignedHeaders=$signed_headers,Signature=$signature"
}

function s3_curl() {
    local method="$1"
    local bucket="$2"
    local filename="$3"
    local querystring="$4"
    local hexdigest="$5"

    shift 5

    local timestamp=$(date -u +%Y%m%dT%H%M%SZ)

    local host="s3.amazonaws.com"
    local uri="/$bucket/$filename"

    local authorization=$(aws_authorization_header "$method" "$AWS_DEFAULT_REGION" "s3" "$host" "$uri" "$querystring" "$timestamp" "$hexdigest")

    curl --fail-with-body --silent \
         --request "$method" \
         --header "Host: $host" \
         --header "x-amz-content-sha256: $hexdigest" \
         --header "x-amz-date: $timestamp" \
         --header "$authorization" \
         "$@" \
        "https://$host$uri$querystring"
}

function s3_get_object() {
    local bucket="$1"
    local filename="$2"

    local hexdigest=$(echo -n "" | sha256)

    s3_curl "GET" "$bucket" "$filename" "" "$hexdigest" --output "$filename"
}

function s3_put_object() {
    local bucket="$1"
    local filename="$2"

    local hexdigest=$(cat "$filename" | sha256)

    s3_curl "PUT" "$bucket" "$filename" "" "$hexdigest" --upload-file "$filename"
}

function s3_delete_object() {
    local bucket="$1"
    local filename="$2"

    local hexdigest=$(echo -n "" | sha256)

    s3_curl "DELETE" "$bucket" "$filename" "" "$hexdigest"
}


## Heroku API

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
                --data @- <<END
{
    "certificate_chain": "$(cat "$certfile" | escape_newlines)",
    "private_key": "$(cat "$keyfile" | escape_newlines)"
}
END
}

function update_sni_endpoint() {
    local id="$1"
    local certfile="$2"
    local keyfile="$3"

    heroku_curl --request PATCH "https://api.heroku.com/apps/$HEROKU_APP_NAME/sni-endpoints/$id" \
                --header "Content-Type: application/json" \
                --data @- <<END
{
    "certificate_chain": "$(cat "$certfile" | escape_newlines)",
    "private_key": "$(cat "$keyfile" | escape_newlines)"
}
END
}

function attach_sni_endpoint() {
    local id="$1"
    local domain="$2"

    heroku_curl --request PATCH "https://api.heroku.com/apps/$HEROKU_APP_NAME/domains/$domain" \
                --header "Content-Type: application/json" \
                --data @- <<END
{
    "sni_endpoint": "$id"
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

function prepend_each_arg() {
    local prefix="$1"
    shift

    for arg in "$@"; do
        echo "$prefix" "$arg"
    done
}

function issue_certificate() {
    local certfile="$1"
    local keyfile="$2"
    local flags="$3"
    shift 3

    "$HOME/.acme.sh/acme.sh" --issue --dns dns_aws --keylength ec-256 --key-file "$keyfile" --fullchain-file "$certfile" --log "$flags" $(prepend_each_arg --domain "$@")
}

function renew_certificates_if_necessary() {
    local flags="$1"

    "$HOME/.acme.sh/acme.sh" --cron --log "$flags"
}

function save_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    echo "Saving cache to s3://$bucket/$cachefile"
    tar -czf "$cachefile" -C "$(dirname "$cachedir")" "$(basename "$cachedir")"
    s3_put_object "$bucket" "$cachefile"
}

function restore_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    echo "Restoring cache from s3://$bucket/$cachefile"
    if ! s3_get_object "$bucket" "$cachefile"; then
        echo "Cache not found. Starting fresh."
        return
    fi

    tar -xzf "$cachefile" -C $(dirname "$cachedir")
}

function usage() {
    echo "usage: $0 [--staging] issue [--force-install] <primary-domain> [additional-domains ...]"
    echo "       NOTE: If you're issuing a wildcard certificate, put it in quotes (e.g. \"*.example.com\")!"
    echo
    echo "       $0 [--staging] clear-cache"
}   

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

if [ "$1" = "--help" -o "$1" == "help" ]; then
    usage
    exit 0
fi

staging=false

if [ "$1" = "--staging" ]; then
    staging=true
    shift
fi

checkenv AWS_ACCESS_KEY_ID
checkenv AWS_SECRET_ACCESS_KEY
checkenv AWS_DEFAULT_REGION
checkenv CERTS_BUCKET
checkenv LETS_ENCRYPT_EMAIL
checkenv HEROKU_APP_NAME
checkenv HEROKU_API_KEY

cachedir="$HOME/.acme.sh"

if [ "$staging" = true ]; then
    acmeflags="--staging"
    cachefile="${HEROKU_APP_NAME}.staging.tar.gz"
else
    acmeflags=""
    cachefile="${HEROKU_APP_NAME}.tar.gz"
fi

trap "echo 'error: \"$0 $1\" failed'" ERR

case "$1" in
    issue)
        shift

        force_install=false
        if [ "$1" = "--force-install" ]; then
            force_install=true
            shift
        fi

        if [ "$#" -lt 1 ]; then
            echo "error: no domains specified"
            usage
            exit 1
        fi

        primary_domain="$1"

        keyfile="/tmp/$primary_domain.key"
        certfile="/tmp/$primary_domain.crt"

        # We test for the existence of the certificate file to determine if the certificates
        # needed to be installed. Delete them here so that we don't accidentally think the certs
        # have been renewed and need to be installed when they haven't. This only matters in 
        # development – on Heroku, the filesystem is ephemeral, so this is a no-op.
        rm -f "$keyfile" "$certfile"

        restore_cache "$CERTS_BUCKET" "$cachefile" "$cachedir"

        if [ -d "$cachedir" ]; then
            upgrade_acme_sh
            renew_certificates_if_necessary "$acmeflags"
        else
            install_acme_sh "$LETS_ENCRYPT_EMAIL"
            issue_certificate "$certfile" "$keyfile" "$acmeflags" "$@"
        fi

    	save_cache "$CERTS_BUCKET" "$cachefile" "$cachedir"

        # If renew_certificates_if_necessary didn't renew the certificates, they won't be installed into /tmp.
        # If you want to test the Heroku API calls, use --force-install to force the certificates to be be put
        # in /tmp so that certs.sh won't exit early with "Nothing to install."
        if [ "$force_install" = true ]; then
            "$HOME/.acme.sh/acme.sh" --install-cert --domain "$primary_domain" --key-file "$keyfile" --fullchain-file "$certfile"
        fi

        # If the certificate file doesn't exist, then the certificates didn't need to be installed on Heroku.
        if [ ! -f "$certfile" ]; then
            echo "Certificates are up to date. Nothing to install."
            exit 0
        fi

        endpoint_id=$(endpoint_id_to_update "$primary_domain")

        if [ -n "$endpoint_id" ]; then
            echo "Updating certificate for $primary_domain on Heroku"
            update_sni_endpoint "$endpoint_id" "$certfile" "$keyfile" > /dev/null
        else
            echo "Installing new certificate for $primary_domain on Heroku"
            endpoint_id=$(create_sni_endpoint "$certfile" "$keyfile" | jq --raw-output '.id')
            attach_sni_endpoint "$endpoint_id" "$primary_domain" > /dev/null
        fi
        ;;
    clear-cache)
        s3_delete_object "$CERTS_BUCKET" "$cachefile"
        ;;
    *)
        usage
        exit 1
        ;;
esac
