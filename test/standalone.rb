# The layer on its own: a program that loads spinel-http/server, multipart
# and gzip and nothing else (no test harness) builds and serves a query
# value, a multipart field and a gzip JSON body. The client side uses only
# socket and Spinel's zlib package; the gzip inflater is FFI, so the
# snapshot comes from the compiled binary (NOTES.md).
require "socket"
require "zlib"
require "spinel-http/server"
require "spinel-http/multipart"
require "spinel-http/gzip"

# Answers the query value `name` (/query), the multipart field `f`
# (/multipart) and the length of a gzip-encoded JSON body (/gzip).
class StandaloneHandler < SpinelHttp::HttpHandler
  def call(request)
    response = SpinelHttp::Response.new
    response.content_type = "text/plain"
    case request.path
    when "/query"
      response.body = request.query_value("name")
    when "/multipart"
      response.body = request.multipart_form.text_value("f")
    when "/gzip"
      response.body = request.decoded_body.bytesize.to_s
    else
      response.status = 404
      response.body = "Not Found"
    end
    response
  end
end

# Sends one request and prints the status code and the body.
def exchange(port, head, body)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(head + "Host: standalone\r\nConnection: close\r\n\r\n" + body)
  buf = +""
  loop do
    break if sock.wait_readable(5).nil?

    begin
      buf << sock.readpartial(16384)
    rescue EOFError, Errno::ECONNRESET
      break
    end
  end
  sock.close
  idx = buf.index("\r\n\r\n")
  if idx.nil?
    puts "no response head: #{buf.inspect}"
  else
    status = buf[0, buf.index("\r\n")].split(" ")[1]
    puts "#{status} #{buf[idx + 4, buf.length - idx - 4]}"
  end
end

server = SpinelHttp::Server.new(StandaloneHandler.new, port: 0)
server.start
port = server.port

exchange(port, "GET /query?name=alice HTTP/1.1\r\n", "")

form = "--XyZ\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nhello\r\n--XyZ--\r\n"
exchange(port, "POST /multipart HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=XyZ\r\n" \
               "Content-Length: #{form.bytesize}\r\n", form)

gz = Zlib.gzip("{\"a\":\"bcd\"}")
exchange(port, "POST /gzip HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n" \
               "Content-Length: #{gz.bytesize}\r\n", gz)

server.stop
