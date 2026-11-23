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
spinel-http = { git = "https://github.com/saeki-mototsune/spinel-http", ref = "v0.1.0" }
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
SpinelHttp::Server.new(Hello.new, port: port).start
sleep
```

```
$ spin build && PORT=8080 build/bin/hello &
$ curl http://127.0.0.1:8080/
hello
```

## Optional requires

`require "spinel-http"` loads the server and what it serves with. Two
features are separate files, so a program that does not need them does not
pay for them:

- `require "spinel-http/multipart"`: multipart/form-data parsing. Without it
  a multipart body is answered 415.
- `require "spinel-http/gzip"`: gzip request bodies. It links zlib, so the
  zlib headers must be installed. Without it a gzip body is answered 400.

`spinel-http/cookies` and `spinel-http/sse` are also loaded on request.

## Compilers

Spinel 2026.10.25 and later (upstream), and the saeki-mototsune/spinel fork.
CI builds and tests with both.

## Tests

```
script/check-standalone   # the library requires nothing outside spinel-http/
spin test                 # the test programs, compared with test/*.expected
```

To run both under upstream, put it first on `PATH`:

```
PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH script/check-standalone
PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH spin test
```

## Notes

NOTES.md lists the rules the code follows to compile and run correctly
under Spinel, each with the reason for it.

## License

MIT, see LICENSE.
