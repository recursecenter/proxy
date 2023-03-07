#!/bin/bash

set -e # Exit immediately if a command fails
set -E # Trigger the ERR trap when a command fails
set -u # Treat unset variables as an error
set -f # Disable file globbing
set -o pipefail # Fail a pipe if any subcommand fails

set -x

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

function s3_get_object() {
    local bucket="$1"
    local filename="$2"

    local timestamp=$(date -u +%Y%m%dT%H%M%SZ)

    local hexdigest=$(echo -n "" | openssl dgst -sha256)

    local host="s3.amazonaws.com"
    local canonical_uri="/$bucket/$filename"
    local canonical_querystring=""

    local authorization=$(aws_authorization_header "GET" "$AWS_DEFAULT_REGION" "s3" "$host" "$canonical_uri" "$canonical_querystring" "$timestamp" "$hexdigest")

    curl -v --silent \
         --header "Host: $host" \
         --header "x-amz-content-sha256: $hexdigest" \
         --header "x-amz-date: $timestamp" \
         --header "$authorization" \
         --output "$filename" \
         "https://$host$canonical_uri"
}

s3_get_object "certs.sh" "recurse-proxy.staging.tar.gz"
