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
