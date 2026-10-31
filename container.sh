# Shared by run.sh and test.sh: container engine, hardened runtime flags, TLS
# certificates, and helpers to start/stop the nginx -> Apache stack.
ENGINE=${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}

# Read-only root filesystem, no Linux capabilities, and no privilege escalation.
HARDENING="--read-only --cap-drop=ALL --security-opt=no-new-privileges"
APP_HARDENING="$HARDENING \
  --tmpfs /var/run/apache2:mode=1777 --tmpfs /var/lock/apache2:mode=1777 --tmpfs /tmp:mode=1777"
PROXY_HARDENING="$HARDENING --tmpfs /tmp:mode=1777"
# Rootless Podman can map the host user to nginx's uid (101), so nginx can read a
# 0600 key file. Docker and rootful Podman can't (keep-id is rootless-only).
PROXY_MAPS_HOST_USER=false
case "$ENGINE" in
    *podman)
        if [ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ]; then
            PROXY_MAPS_HOST_USER=true
            PROXY_HARDENING="$PROXY_HARDENING --userns=keep-id:uid=101,gid=101"
        fi
        ;;
esac

build_images() {
    "$ENGINE" build -q -t phptest . >/dev/null
    "$ENGINE" build -q -t phptest-proxy -f docker/nginx.Dockerfile . >/dev/null
}

# ensure_certs: sets TLS_CERT/TLS_KEY (and TLS_CA for generated certs). Uses
# TLS_CERT/TLS_KEY from the environment if both are given; otherwise creates a
# throwaway local CA and a localhost/127.0.0.1 server certificate in ./certs
# (regenerated when missing or expiring within a day). The CA key is deleted
# after signing, so nothing else can be issued from it.
ensure_certs() {
    if [ -n "${TLS_CERT:-}" ] || [ -n "${TLS_KEY:-}" ]; then
        if [ ! -r "${TLS_CERT:-}" ] || [ ! -r "${TLS_KEY:-}" ]; then
            echo "TLS_CERT and TLS_KEY must both name readable files" >&2
            exit 1
        fi
        return
    fi
    TLS_CERT=$PWD/certs/server.crt TLS_KEY=$PWD/certs/server.key TLS_CA=$PWD/certs/ca.crt
    if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ] && [ -f "$TLS_CA" ] &&
        openssl x509 -checkend 86400 -noout -in "$TLS_CERT" >/dev/null; then
        allow_proxy_key_read
        return
    fi
    echo "Generating a local CA and TLS certificate in ./certs (trust certs/ca.crt to avoid browser warnings)" >&2
    rm -rf certs && mkdir -m 700 certs
    (
        cd certs && umask 077
        printf '%s\n' 'subjectAltName = DNS:localhost, IP:127.0.0.1' 'basicConstraints = critical, CA:FALSE' \
            'keyUsage = critical, digitalSignature' 'extendedKeyUsage = serverAuth' > server.ext
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 90 \
            -subj "/CN=PHPTest local CA" -keyout ca.key -out ca.crt \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign"
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -subj "/CN=localhost" -keyout server.key -out server.csr
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -days 90 -extfile server.ext -out server.crt
        rm -f ca.key server.csr server.ext
        chmod 644 ca.crt server.crt
    ) 2>/dev/null || { echo "certificate generation failed (is openssl installed?)" >&2; exit 1; }
    allow_proxy_key_read
}

# With rootless Podman the generated key stays 0600 (see PROXY_MAPS_HOST_USER).
# Otherwise nginx (uid 101) needs it world-readable; certs/ itself stays 0700, so
# other host users still can't reach it.
allow_proxy_key_read() {
    if [ "$PROXY_MAPS_HOST_USER" = true ]; then
        chmod 600 "$TLS_KEY"
    else
        chmod 644 "$TLS_KEY"
    fi
}

# start_stack <prefix> [publish-spec]: nginx shares the Apache container's network
# namespace, so Apache's port 8000 is never published; only nginx's 8443 is, and
# only if a publish spec (e.g. 127.0.0.1:8000:8443) is given. Sharing the namespace
# (rather than a bridge network) keeps real client IPs visible to nginx under
# rootless Podman, which the per-IP limits depend on. Call ensure_certs first.
start_stack() {
    # shellcheck disable=SC2086
    "$ENGINE" run -d --rm $APP_HARDENING ${2:+-p "$2"} --name "$1-app" phptest >/dev/null
    # shellcheck disable=SC2086
    "$ENGINE" run -d --rm $PROXY_HARDENING --network "container:$1-app" \
        -v "$TLS_CERT:/etc/nginx/tls/server.crt:ro,z" -v "$TLS_KEY:/etc/nginx/tls/server.key:ro,z" \
        --name "$1-proxy" phptest-proxy >/dev/null
}

# The proxy depends on the app's network namespace, so remove it first.
stop_stack() {
    "$ENGINE" rm -f -t 5 "$1-proxy" >/dev/null 2>&1 || true
    "$ENGINE" rm -f -t 5 "$1-app" >/dev/null 2>&1 || true
}
