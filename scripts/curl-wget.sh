#!/bin/sh
set -eu

url=
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            output=$2
            shift 2
            ;;
        http://*|https://*)
            url=$1
            shift
            ;;
        *)
            echo "unsupported wget argument: $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$url" ] || exit 2
[ -n "$output" ] || output=${url##*/}
curl_download() {
    case "$url" in
        http://dl.google.com/*|https://dl.google.com/*)
            curl --noproxy '*' "$@"
            ;;
        *)
            if [ -n "${DOWNLOAD_PROXY:-}" ]; then
                curl --proxy "$DOWNLOAD_PROXY" "$@"
            else
                curl "$@"
            fi
            ;;
    esac
}
if [ "$output" = - ]; then
    curl_download --fail --location --retry 8 --retry-all-errors "$url"
    exit
fi
curl_download --fail --location --retry 8 --retry-all-errors \
    --output "$output" "$url"
