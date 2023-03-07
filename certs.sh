#!/bin/bash

# Wildcard certificates from Let's Encrypt for Heroku apps
#
# Services:
#  - Heroku
#  - Amazon S3
#  - Amazon Route 53
#  - Let's Encrypt
#
# How it works:
#
#  `certs.sh issue` generates or renews a certificate for *.$DOMAIN, and
#  registers it with Heroku.
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
#  Acme.sh state is cached by app name ($HEROKU_APP_NAME.tar.gz), so multiple apps can
#  use the same bucket to cache their state. Staging state is cached
#  separately ($HEROKU_APP_NAME.staging.tar.gz).
#
#  `certs.sh clear-cache` deletes the acme.sh state from S3. Remember to use --staging
#  if you want to clear the staging cache while you're modifying this script.
#
# Dependencies:
#  - curl (comes pre-installed on Heroku)
#  - openssl (ditto)
#  - jq (use the heroku-community/apt buildpack with "jq" in your Aptfile)
#  - acme.sh (installed and managed by this script)
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
#    it uses server-side encryption wtih S3 managed keys (SSE-S3). This is the default as of March 2023.
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

function hmac_sha256 {
    local key="$1"
    local data="$2"

    echo -n "$data" | openssl dgst -sha256 -mac HMAC -macopt "$key"
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
$(echo -n "$canonical_request" | openssl dgst -sha256)"

    local date_key=$(hmac_sha256 key:"AWS4$AWS_SECRET_ACCESS_KEY" "$datestamp")
    local date_region_key=$(hmac_sha256 hexkey:"$date_key" "$region")
    local date_region_service_key=$(hmac_sha256 hexkey:"$date_region_key" "$service")
    local signing_key=$(hmac_sha256 hexkey:"$date_region_service_key" "aws4_request")

    local signature=$(hmac_sha256 hexkey:"$signing_key" "$string_to_sign")

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

    curl --fail --silent \
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

    local hexdigest=$(echo -n "" | openssl dgst -sha256)

    s3_curl "GET" "$bucket" "$filename" "" "$hexdigest" --output "$filename"
}

function s3_put_object() {
    local bucket="$1"
    local filename="$2"

    local hexdigest=$(cat "$filename" | openssl dgst -sha256)

    s3_curl "PUT" "$bucket" "$filename" "" "$hexdigest" --upload-file "$filename"
}

function s3_delete_object() {
    local bucket="$1"
    local filename="$2"

    local hexdigest=$(echo -n "" | openssl dgst -sha256)

    s3_curl "DELETE" "$bucket" "$filename" "$hexdigest"
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

function save_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    tar -czf "$cachefile" -C "$(dirname "$cachedir")" "$(basename "$cachedir")"
    s3_put_object "$bucket" "$cachefile"
}

function restore_cache() {
    local bucket="$1"
    local cachefile="$2"
    local cachedir="$3"

    if ! s3_get_object "$bucket" "$cachefile"; then
        return
    fi

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
        s3_delete_object "$CERTS_BUCKET" "$cachefile"
        ;;
    *)
        echo "Usage: $0 [--staging] <issue|clear-cache>"
        exit 1
        ;;
esac
