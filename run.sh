#!/usr/bin/env sh
# Serves the app on https://127.0.0.1:8000 (this machine only) via nginx (TLS) -> Apache + PHP 8.4.
# Set BIND=0.0.0.0 to expose it to the network, and TLS_CERT/TLS_KEY to use your
# own certificate. Ctrl+C stops both containers.
set -e
cd "$(dirname "$0")"
. ./container.sh
ensure_certs
build_images
stop_stack phptest
trap 'stop_stack phptest' EXIT INT TERM
start_stack phptest "${BIND:-127.0.0.1}:8000:8443"
echo "Serving on https://${BIND:-127.0.0.1}:8000 (Ctrl+C to stop)"
"$ENGINE" logs -f phptest-proxy
