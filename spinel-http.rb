# spinel-http: an HTTP/1.1 server and request/response library for Spinel.
#
# `require "spinel-http"` loads the server and what it serves with:
# SpinelHttp::Server, HttpHandler, Request, Response, Query, Params,
# UploadedFile, ClientError and the log bases. Cookies, SSE, multipart and
# gzip are not loaded by it: require "spinel-http/cookies",
# "spinel-http/sse", "spinel-http/multipart" (without it a multipart body
# is a 415), "spinel-http/gzip" (without it a gzip body is a 400) or
# "spinel-http/gzip_decoder" for them.
require "spinel-http/server"

module SpinelHttp
  VERSION = "0.2.0"
end
