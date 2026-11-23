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
