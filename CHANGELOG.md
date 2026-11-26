# Changelog

## 0.2.0

- **Security (CWE-400, slowloris):** `read_timeout` bounded each wait for
  more bytes but not the request, so a client that sent a byte just inside
  each wait held its connection and thread indefinitely. Two new
  `Server.new` options bound the whole request: `head_timeout:` (default
  30 s, counted from the head's first byte, so an idle keep-alive wait is
  still `read_timeout`'s) and `body_timeout:` (default 120 s, from the end
  of the head). Past either the server answers 408 and closes.
- `max_connections:` (default 1024) caps the connections open at once.
  One accepted over it is answered a prebuilt 503 and closed on the accept
  thread, with no thread of its own; a warning is logged once each time
  the cap is reached.
- The deadlines cost two monotonic clock readings per wait and nothing
  allocated per request.

## 0.1.2

- **Security:** when a response is refused because a header stored through
  `Response#headers` directly has CR or LF in its name, the server's log
  line quotes the name (String#inspect) instead of writing it as it is, so
  the name can no longer start a forged log line.
- CI tests with the fork 2026.11.23.7035 (was 2026.11.15.7033), the
  release cybertrain 0.4.2 uses. 0.1.1 passes all 17 programs under it.

## 0.1.1

- **Security:** the parser answers 400 for CR, LF or NUL anywhere in the
  request line or a header line (RFC 9110 section 5.5), and for a header
  name that is not a token. A bare LF inside a header line used to be kept
  in the value, so `"X: a\nTransfer-Encoding: chunked"` hid a header from
  this server that a front end ending lines at LF would see.
- A header or cookie with CR or LF that was stored through
  `Response#headers` or `#cookies` directly, which skips `set_header`'s
  check, is no longer written: `to_http` raises ArgumentError and the
  server answers 500.
- README: running behind a reverse proxy, which errors become which
  status, the limits and timeouts and how to set them, graceful shutdown,
  the one-name-one-return-type rule for programs built on the layer, and
  how to build upstream Spinel for the tests. The example now stops on
  TERM with `run` and a trap.
- `@api public` marks the stable surface, now including `Server`,
  `HttpHandler`, `PortInUse`, `Params`, `Query`, `ClientError`,
  `Multipart.configure`, `StreamFailure`, `SpinelHttp.stream_failure=` and
  `Request.entry_quality`.
- Tests for `client_ip`, `trusted_proxies`, `base_url`, `IpAddress`,
  streamed and upgraded responses, the stream-failure hook, the
  `X-Request-Id` echo and `negotiate_locale`, under both compilers.
- `script/check-standalone` also scans `spinel-http.rb` and checks that
  `SpinelHttp::VERSION` matches spin.toml.

## 0.1.0 (9894060)

The HTTP layer of a web framework, extracted as `SpinelHttp`: the server,
requests and responses, query and parameter parsing, cookies, server-sent
events, and multipart and gzip bodies behind their own requires. Built and
tested with upstream Spinel 2026.10.25 and the fork 2026.11.15.7033.
