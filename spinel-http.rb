# spinel-http: an HTTP/1.1 server and request/response library for Spinel.
#
# `require "spinel-http"` loads the server and what it serves with:
# SpinelHttp::Server, HttpHandler, Request, Response, Query, Params,
# Multipart, UploadedFile, ClientError and the log bases. Cookies, SSE and
# GzipDecoder are not loaded by it: require "spinel-http/cookies",
# "spinel-http/sse" or "spinel-http/gzip_decoder" for them.
require "spinel-http/server"

module SpinelHttp
  VERSION = "0.1.0"
end
