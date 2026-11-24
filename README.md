# spinel-http

An HTTP/1.1 server library for [Spinel](https://github.com/matz/spinel)
(module `SpinelHttp`). It was extracted from a web framework but has no
framework concepts: you give it a handler, it parses requests, calls the
handler and writes the response. It also offers query and parameter parsing,
cookies and server-sent events.

## Hello world

Add the library to your `spin.toml`:

```toml
[dependencies]
spinel-http = { git = "https://github.com/saeki-mototsune/spinel-http", ref = "v0.1.1" }
```

`bin/hello.rb` (also built and checked in CI as `examples/hello`):

```ruby
require "spinel-http"

# Answers every request with "hello".
class Hello < SpinelHttp::HttpHandler
  def call(request)
    response = SpinelHttp::Response.new
    response.content_type = "text/plain"
    response.body = "hello"
    response
  end
end

port = (ENV["PORT"] || "8080").to_i
server = SpinelHttp::Server.new(Hello.new, port: port)
# TERM (systemd, docker stop) and Ctrl-C stop the server: it stops
# accepting, answers the requests in flight, and run returns.
trap("TERM") { server.request_stop }
trap("INT") { server.request_stop }
server.run
```

```
$ spin build && PORT=8080 build/bin/hello &
$ curl http://127.0.0.1:8080/
hello
```

`server.run` binds (raising `SpinelHttp::PortInUse` when it cannot), serves,
and returns once a stop was requested and the open connections have drained.
`request_stop` only sets a flag, which is what a signal handler may do.
Requests being processed get their response with `Connection: close`, idle
keep-alive connections are closed, and `run` waits at most `drain_timeout`
seconds (10 by default; keep it below your process manager's stop timeout).
`server.start` and `server.wait` are the two halves of `run`, and
`server.stop` stops and drains from ordinary code.

## Optional requires

`require "spinel-http"` loads the server and what it serves with. Four
features are separate requires, so a program that does not need them does
not pay for them:

- `require "spinel-http/multipart"`: multipart/form-data parsing. Without
  it, a handler that reads a multipart form gets a 415.
- `require "spinel-http/gzip"`: gzip request bodies. It links zlib, so the
  zlib headers must be installed. Without it, a handler that reads a gzip
  body with `request.decoded_body` gets a 400.
- `require "spinel-http/cookies"`: `SpinelHttp::Cookies`.
- `require "spinel-http/sse"`: `SpinelHttp::SSE`, server-sent events.

## Behind a reverse proxy

Put a reverse proxy (nginx, Caddy, a load balancer) in front of the server
on the internet. The server has no limit on the number of connections and
no deadline for a whole request (see Timeouts), so a proxy that buffers
requests and enforces its own timeouts is what protects it from slow
clients.

Behind a proxy, `request.remote_addr` is the proxy's address. To have
`request.client_ip` answer the client's, tell the layer which peers are
proxies, once at boot:

```ruby
SpinelHttp::Request.trusted_proxy = true                     # a proxy on this host (loopback)
SpinelHttp::Request.trusted_proxies = ["172.16.0.0/12"]      # proxies elsewhere: addresses or CIDRs
```

A connection from a trusted peer has its client taken from the last hop of
`X-Forwarded-For`, which is the one the proxy appended; earlier hops are
whatever the client wrote and are never used. Any other connection's
`client_ip` is its peer address, whatever headers it sends. `request.base_url`
answers `https://<host>` only when a trusted peer sends
`X-Forwarded-Proto: https`. `request.loopback?` never reads the headers. Both
settings are off until set.

## Errors and status codes

The server answers these itself and closes the connection:

| Status | When |
| --- | --- |
| 400 | A malformed request line or header line, a header name that is not a token, CR, LF or NUL in the head, a head over `max_head_bytes`, or an invalid or duplicated Content-Length. |
| 411 | Any Transfer-Encoding: chunked request bodies are not supported. |
| 413 | A Content-Length over `max_body_bytes`. The body is not read. |

An exception that escapes your handler's `call` is answered by the
server, and the connection stays open:

| Status | Exception |
| --- | --- |
| 400 | `SpinelHttp::QueryInvalid` and its subclasses: parameters past Query's limits or not valid UTF-8, a multipart body past its limits, a body that cannot be decoded or is over `decoded_body`'s limit. Logged at info. |
| 415 | `SpinelHttp::UnsupportedMediaType`: a multipart form read when `spinel-http/multipart` is not required. |
| 500 | Anything else. Logged at error as `Class: message`. |

These come from the readers, so a handler that never reads the query, the
form or the body never raises them. To answer an error your own way, rescue
it inside `call`. To have one of your own exception classes answered 400,
register its full name at boot:

```ruby
require "spinel-http/extra_faults"
SpinelHttp::ClientError.extra_faults = SpinelHttp::ClientError.extra_faults + ["MyApp::BadInput"]
```

`SpinelHttp::ClientError.status_for(e)` answers 400, 415 or 500 for an
exception, for an error page of your own. The server logs through the
`logger:` you pass to `Server.new`, an `SpinelHttp::HttpLog` subclass; the
default writes `level: message` lines to standard error.

Known deviations from RFC 9112 and RFC 9110: an HTTP/1.1 request without a
Host header is served (check Host in your handler if you rely on it), and
`base_url` uses Host as sent; an oversized head is a 400, not a 431; a
decoded body over its limit is a 400, not a 413.

## Limits

| Limit | Default | Set with |
| --- | --- | --- |
| Request head | 64 KiB | `Server.new(..., max_head_bytes:)` |
| Request body, as sent | 10 MiB | `Server.new(..., max_body_bytes:)` |
| Decoded (gunzipped) body | 10 MiB | `request.decoded_body(limit)` |
| One uploaded file | 5 MiB | `SpinelHttp::Multipart.configure(max_upload_bytes, max_parts)` |
| Parts in one multipart body | 128 | the same call |
| Query and form parameters | 4096 pairs, 32 levels of nesting | fixed |

`Multipart.configure` and the `trusted_proxy` settings are module-level:
call them once at boot, before the server starts.

## Timeouts

| Timeout | Default | What it bounds |
| --- | --- | --- |
| `read_timeout:` | 15 s | each wait for more bytes of a request, and an idle keep-alive connection |
| `stream_write_timeout:` | 15 s | each write of a streamed response to a client that does not read |
| `drain_timeout:` | 10 s | the wait for requests in flight once a stop is requested |

`read_timeout` limits each read, not the whole request: a client that sends
one byte every few seconds keeps its connection, and the buffer it fills up
to `max_head_bytes` or `max_body_bytes`, for as long as it keeps sending.
There is no connection cap either. Do not expose the server to the internet
without a proxy in front.

## One method name, one return type

Spinel infers types for the whole program at once, and two methods with the
same name but different return types can miscompile it (NOTES.md rule 6).
That holds for your program too: your methods share one namespace with the
layer's. Give a method of yours that shares a name with one of the layer's
the same return type, or pick a distinctive name. To list the layer's
method names:

```
grep -rhoE 'def (self\.)?[a-z0-9_]+[?!=]?' spinel-http/ | sed -E 's/def (self\.)?//' | sort -u
```

## API

The classes and methods tagged `@api public` in the source are the stable
surface; those tagged `@api private`, or not tagged, may change in any
release.

## Compilers

Upstream Spinel 2026.10.25 (matz/spinel) and the saeki-mototsune/spinel
fork 2026.11.23.7035. CI builds and tests with both. An older Spinel
(such as 2026.09.12) does not build it: `spin test` fails in server.rb
and response.rb.

## Tests

```
script/check-standalone   # nothing outside spinel-http/ is required; VERSION matches spin.toml
spin test                 # the test programs, compared with test/*.expected
```

To run them under upstream Spinel as CI's `upstream` job does, build it once:

```
tag=2026.10.25
up=$HOME/.spinel-upstream/$tag
src=$(mktemp -d)
git clone -q --depth 1 --branch "$tag" https://github.com/matz/spinel "$src"
(cd "$src" && make deps && make -j"$(nproc)" && make install PREFIX="$up")
```

Then put it first on `PATH`, in an export of the tree outside the checkout,
so the two compilers do not share `build/` (commit first: the export is of
`HEAD`):

```
dir=$(mktemp -d)
git archive HEAD | tar -x -C "$dir"
cd "$dir"
PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH script/check-standalone
PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH spin test
```

## Notes

NOTES.md lists the rules the code follows to compile and run correctly
under Spinel, each with the reason for it. CHANGELOG.md lists the releases.

## License

MIT, see LICENSE.
