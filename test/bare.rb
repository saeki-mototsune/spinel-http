# The layer with neither optional file: a program that requires only
# spinel-http/server. A multipart body is a 415 (the null parser answers
# UnsupportedMediaType, which ClientError classifies), its boundary is "",
# and a gzip body is a 400 whose log line names the missing inflater (the
# error response itself carries no message). The compiled binary
# prints the snapshot.
require "socket"
require "spinel-http/server"
require "stringio"
require_relative "support/check"
require_relative "support/log_capture"

# /multipart reads the form, /boundary answers the boundary, /body decodes
# the body, anything else answers 200.
class BareApp < SpinelHttp::HttpHandler
  def call(request)
    response = SpinelHttp::Response.new
    response.content_type = "text/plain"
    case request.path
    when "/multipart"
      response.body = request.multipart_form.text_value("f")
    when "/boundary"
      response.body = "[" + request.multipart_boundary + "]"
    when "/body"
      response.body = request.decoded_body
    else
      response.body = "hello"
    end
    response
  end
end

# One request; the status code and the body of the answer.
class BareAnswer
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
  end
end

def bare_exchange(port, head, body)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(head + "Host: bare\r\nConnection: close\r\n\r\n" + body)
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
  return BareAnswer.new("", buf) if idx.nil?

  status = buf[0, buf.index("\r\n")].split(" ")[1].to_s
  BareAnswer.new(status, buf[idx + 4, buf.length - idx - 4].to_s)
end

log = StringIO.new
server = SpinelHttp::Server.new(BareApp.new, port: 0, logger: TestLog.new(log))
server.start
port = server.port

FORM = "--XyZ\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nhello\r\n--XyZ--\r\n"
MULTIPART_HEAD = "POST /multipart HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=XyZ\r\n" \
                 "Content-Length: #{FORM.bytesize}\r\n"

test "a multipart POST is answered 415 when multipart is not loaded" do
  answer = bare_exchange(port, MULTIPART_HEAD, FORM)
  assert_equal "415", answer.status
  expected = "INFO rejected request (415 Unsupported Media Type): multipart/form-data bodies are not supported"
  assert_equal 1, LogCapture.count(log.string, "INFO", expected[5, expected.length - 5])
end

test "multipart_boundary is empty when multipart is not loaded" do
  head = "POST /boundary HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=XyZ\r\nContent-Length: 0\r\n"
  answer = bare_exchange(port, head, "")
  assert_equal "200", answer.status
  assert_equal "[]", answer.body
end

test "a gzip body is answered 400 naming the missing inflater" do
  gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\x4c\x4a\x06\x00\xc2\x41\x24\x35\x03\x00\x00\x00".b
  head = "POST /body HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n" \
         "Content-Length: #{gz.bytesize}\r\n"
  answer = bare_exchange(port, head, gz)
  assert_equal "400", answer.status
  said = "gzip request bodies are not decoded: no inflater is installed (require \"spinel-http/gzip\")"
  assert_equal 1, LogCapture.count(log.string, "INFO", "rejected request (400 Bad Request): " + said)
end

test "a plain GET is answered 200" do
  answer = bare_exchange(port, "GET /hello HTTP/1.1\r\n", "")
  assert_equal "200", answer.status
  assert_equal "hello", answer.body
end

server.stop
SpinelHttpTest.summary
