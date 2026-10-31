# PHPTest

A minimal web server on port 8000 that replies `Hello PHP8.4 world`, served by
Apache + mod_php on PHP 8.4 (official `php:8.4-apache` image) behind an nginx
TLS-terminating reverse proxy (official `nginx:stable-alpine` image).

```
client --HTTPS--> nginx :8443 (published as host :8000) --HTTP--> Apache :8000 (not published)
```

nginx shares the Apache container's network namespace, so Apache is reachable
only through nginx, and nginx sees real client IPs (needed for per-IP limits).

## Layout

- `public/index.php` – the request handler (copied to Apache's `/var/www/html`)
- `tests/ServerTest.php` – asserts a 200 response with the hello message, the
  security headers, and no version disclosure in headers or error pages. It runs
  twice: against Apache started inside the test container, and end to end
  through nginx (`BASE_URL`), where it also checks that rate limiting returns 429
- `Dockerfile` – app `runtime` image (default) and a `test` image that adds `tests/`
- `docker/nginx.Dockerfile`, `docker/nginx.conf` – reverse proxy image, TLS and limits
- `docker/apache-hardening.conf`, `docker/php-hardening.ini` – server hardening
- `container.sh` – container engine, hardened run flags, certificate generation,
  and stack start/stop helpers shared by the scripts
- `certs/` – generated local CA and server certificate (git-ignored)

## Usage

Requires Podman or Docker (set `CONTAINER_ENGINE` to choose one) and `openssl`.

```sh
./run.sh                 # serve on https://127.0.0.1:8000 (this machine only); Ctrl+C stops it
BIND=0.0.0.0 ./run.sh    # expose on all network interfaces
./test.sh                # run the tests (Apache directly, then via nginx over TLS)
CONTAINER_ENGINE=docker ./test.sh   # force Docker instead of Podman

curl --cacert certs/ca.crt https://localhost:8000/
```

Plain `http://` requests to port 8000 are redirected to `https://`.

### Certificates

By default `run.sh` creates a throwaway local CA and a certificate for
`localhost` and `127.0.0.1` in `certs/` (valid 90 days, regenerated when it
expires or is deleted). The CA's private key is deleted right after signing, so
nothing else can be issued from it. To stop browser warnings, import
`certs/ca.crt` as a trusted authority, or accept the warning.

To use your own certificate (e.g. from Let's Encrypt for a real hostname):

```sh
TLS_CERT=/path/fullchain.pem TLS_KEY=/path/privkey.pem BIND=0.0.0.0 ./run.sh
```

The key is mounted read-only into nginx at run time and never built into an
image. With Podman the key can stay `chmod 600`. With Docker the nginx user
(uid 101) must be able to read it: the generated key is made readable inside the
`0700` `certs/` directory automatically; for your own key use e.g.
`sudo chown 101 privkey.pem`.

## CI

`.github/workflows/test.yml` runs `./test.sh` on every push to `master` and on
pull requests, once with Podman and once with Docker.

## Security hardening

nginx (in front):
- TLS 1.2 and 1.3 only (Mozilla "intermediate" ciphers, forward secrecy),
  HTTP/2, session tickets off. TLS 1.0/1.1 are refused.
- HSTS is commented out in `docker/nginx.conf`. Enable it once this is served
  on a real hostname. Browsers apply it to every port on `localhost`, which
  would force HTTPS on your other local dev servers.
- Per-client-IP limits: 20 concurrent requests and 20 requests/s (burst 40);
  excess requests get `429`. Tune in `docker/nginx.conf`.
- Holds idle/slow connections cheaply and drops them after 10s, so connection
  floods never reach Apache.
- `server_tokens off`, 1 MB body limit, runs as `nginx` (non-root).

Apache + PHP (behind nginx):
- `php.ini-production` plus `expose_php = Off`; `ServerTokens Prod` and
  `ServerSignature Off`, so no PHP/Apache/OS versions are disclosed.
- Security headers: `X-Content-Type-Options`, `X-Frame-Options`,
  `Content-Security-Policy`, `Referrer-Policy`.
- Request timeouts and size limits; directory listings (`autoindex`),
  `/server-status` and `TRACE` are disabled. Runs as `www-data`.

Both containers:
- Read-only root filesystem, no Linux capabilities, `no-new-privileges`.
- Published on `127.0.0.1` by default; test code is not in the runtime image.

Note: Apache logs nginx's address as the client; the real IP is in nginx's
access log and the `X-Forwarded-For` header.
