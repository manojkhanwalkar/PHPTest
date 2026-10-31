#!/usr/bin/env sh
# 1. Starts Apache inside the test container and checks it directly.
# 2. Starts the full nginx (TLS) -> Apache stack and checks it through the proxy:
#    certificate verified against the local CA, HTTP->HTTPS redirect, old TLS
#    versions refused, and the per-client rate limit.
set -e
cd "$(dirname "$0")"
. ./container.sh
unset TLS_CERT TLS_KEY   # always test with the generated local CA
ensure_certs
build_images
"$ENGINE" build -q --target test -t phptest-test . >/dev/null

# shellcheck disable=SC2086
"$ENGINE" run --rm $APP_HARDENING phptest-test

stop_stack phptest-e2e
trap 'stop_stack phptest-e2e' EXIT INT TERM
start_stack phptest-e2e
# shellcheck disable=SC2086
"$ENGINE" run --rm $HARDENING --network container:phptest-e2e-app \
    -v "$TLS_CA:/app/ca.crt:ro,z" -e CA_FILE=/app/ca.crt \
    -e BASE_URL=https://localhost:8443 -e EXPECTED_SERVER=nginx phptest-test
