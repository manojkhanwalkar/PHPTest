<?php
// Checks the web server's reply and security headers. Dependency-free (no
// PHPUnit/Composer needed). Exits non-zero on failure.
//
// Default: starts Apache on port 8000 in this container and tests it directly.
// With BASE_URL set (e.g. https://localhost:8443): tests an already-running server,
// expecting the Server header EXPECTED_SERVER (default "Apache"); for "nginx" it
// also checks that the per-client rate limit answers 429. For https URLs the
// certificate is verified against CA_FILE, plain HTTP must redirect to HTTPS, and
// TLS 1.0/1.1 must be refused.

declare(strict_types=1);

const EXPECTED_BODY = 'Hello PHP8.4 world';

function fail(string $message): never
{
    fwrite(STDERR, "FAIL: $message\n");
    exit(1);
}

/** @return array{int, array<string, string>, string} status, lower-cased headers, body */
function get(string $url, array $requestHeaders = []): array
{
    $context = stream_context_create([
        'http' => ['timeout' => 5, 'ignore_errors' => true, 'follow_location' => 0, 'header' => $requestHeaders],
        'ssl' => tlsOptions(),
    ]);
    $body = file_get_contents($url, false, $context);
    if ($body === false) {
        fail("request to $url failed");
    }
    $statusLine = array_shift($http_response_header);
    if (!preg_match('#^HTTP/\S+ (\d{3})#', $statusLine, $m)) {
        fail("unexpected status line: $statusLine");
    }
    $headers = [];
    foreach ($http_response_header as $line) {
        [$name, $value] = array_map('trim', explode(':', $line, 2)) + [1 => ''];
        $headers[strtolower($name)] = $value;
    }
    return [(int) $m[1], $headers, $body];
}

/** Verify the server certificate (against CA_FILE if given); never skip verification. */
function tlsOptions(array $extra = []): array
{
    $options = ['verify_peer' => true, 'verify_peer_name' => true];
    if ($caFile = getenv('CA_FILE')) {
        $options['cafile'] = $caFile;
    }
    return $extra + $options;
}

/** Starts Apache in this container and waits until it listens on port 8000. */
function startApache(): void
{
    // "exec" makes the server replace the shell, so proc_terminate() stops it directly.
    $server = proc_open('exec apache2-foreground', [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    if (!is_resource($server)) {
        fail('could not start the web server');
    }
    register_shutdown_function(function () use ($server): void {
        proc_terminate($server);
        proc_close($server);
    });
    waitForServer('127.0.0.1', 8000, fn () => proc_get_status($server)['running']);
}

function waitForServer(string $host, int $port, ?callable $isAlive = null): void
{
    $deadline = microtime(true) + 10;
    while (!($sock = @fsockopen($host, $port, $errno, $errstr, 0.2))) {
        if ($isAlive !== null && !$isAlive()) {
            fail("web server exited early (is port $port already in use?)");
        }
        if (microtime(true) > $deadline) {
            fail("web server did not start listening on $host:$port");
        }
        usleep(100_000);
    }
    fclose($sock);
}

$baseUrl = getenv('BASE_URL') ?: '';
$expectedServer = getenv('EXPECTED_SERVER') ?: 'Apache';
if ($baseUrl === '') {
    $baseUrl = 'http://127.0.0.1:8000';
    startApache();
} else {
    $parts = parse_url($baseUrl);
    waitForServer($parts['host'], $parts['port'] ?? 80);
}

// The proxy may answer 502 briefly while Apache is still starting.
$deadline = microtime(true) + 10;
while (true) {
    [$status, $headers, $body] = get("$baseUrl/");
    if ($status !== 502 || microtime(true) > $deadline) {
        break;
    }
    usleep(200_000);
}

if ($status !== 200) {
    fail("expected HTTP 200, got $status");
}
if (trim($body) !== EXPECTED_BODY) {
    fail("expected body '" . EXPECTED_BODY . "', got '" . trim($body) . "'");
}

// Hardening checks: no version disclosure, security headers present.
if (isset($headers['x-powered-by'])) {
    fail("X-Powered-By header is exposed: {$headers['x-powered-by']}");
}
if (($headers['server'] ?? '') !== $expectedServer) {
    fail("Server header should be just '$expectedServer', got '" . ($headers['server'] ?? '') . "'");
}
foreach (['x-content-type-options' => 'nosniff', 'x-frame-options' => 'DENY'] as $name => $value) {
    if (($headers[$name] ?? '') !== $value) {
        fail("expected header $name: $value");
    }
}

// Error pages must not leak the server version.
[$status, , $body] = get("$baseUrl/does-not-exist");
if ($status !== 404 || preg_match('/Apache\/\d|nginx\/\d|Debian|PHP\/\d/', $body)) {
    fail("404 page should not disclose versions (status $status)");
}

// TLS only: plain HTTP must redirect to HTTPS, and pre-1.2 TLS must be refused.
if (str_starts_with($baseUrl, 'https://')) {
    // The redirect must keep the host:port the client used (e.g. the published host
    // port), not the container's internal port, so send a different Host header.
    $httpUrl = 'http://' . substr($baseUrl, strlen('https://'));
    [$status, $headers] = get("$httpUrl/a/b?c=1", ['Host: localhost:12345']);
    $expected = 'https://localhost:12345/a/b?c=1';
    if ($status !== 301 || ($headers['location'] ?? '') !== $expected) {
        fail("plain HTTP should 301 to $expected, got $status to '" . ($headers['location'] ?? '') . "'");
    }

    // Offer only TLS 1.0/1.1 (SECLEVEL=0 allows it). The server must answer with a
    // "protocol version" alert; any other failure (e.g. this client being unable to
    // offer old TLS at all) would make the check meaningless, so it fails the test.
    $parts = parse_url($baseUrl);
    $context = stream_context_create(['ssl' => tlsOptions([
        'crypto_method' => STREAM_CRYPTO_METHOD_TLSv1_0_CLIENT | STREAM_CRYPTO_METHOD_TLSv1_1_CLIENT,
        'ciphers' => 'DEFAULT@SECLEVEL=0',
    ])]);
    $warnings = [];
    set_error_handler(function (int $no, string $message) use (&$warnings): bool {
        $warnings[] = $message;
        return true;
    });
    $old = stream_socket_client("tls://{$parts['host']}:{$parts['port']}", $errno, $errstr, 5, STREAM_CLIENT_CONNECT, $context);
    restore_error_handler();
    if ($old !== false) {
        fail('server accepted a TLS 1.0/1.1 connection');
    }
    if (!str_contains(implode("\n", $warnings), 'alert protocol version')) {
        fail("expected the server to refuse TLS 1.0/1.1 with a protocol-version alert, got:\n" . implode("\n", $warnings));
    }
    echo "PASS: HTTP redirects to HTTPS; certificate verified; TLS 1.0/1.1 refused\n";
}

// Proxy only: a burst well above 20 req/s (+40 burst) must be throttled.
if ($expectedServer === 'nginx') {
    $throttled = 0;
    for ($i = 0; $i < 100; $i++) {
        [$status] = get("$baseUrl/");
        $throttled += $status === 429 ? 1 : 0;
    }
    if ($throttled === 0) {
        fail('expected some of 100 rapid requests to be rate-limited with 429');
    }
    echo "PASS: rate limit returned 429 for $throttled of 100 rapid requests\n";
}

echo "PASS: GET $baseUrl/ returned 200 '" . EXPECTED_BODY . "' with hardened headers (Server: $expectedServer)\n";
