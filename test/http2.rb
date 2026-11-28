# SpinelHttp::Server over HTTP/2 (h2c with prior knowledge, RFC 9113): a
# real server on an ephemeral port, driven by a small HTTP/2 client written
# here on a TCPSocket, with the layer's own HPACK encoder and decoder. Only
# statuses, header lines, bodies and error codes are compared, never the
# port.
require "socket"
require "stringio"
require "spinel-http/server"
require_relative "support/check"
require_relative "support/log_capture"

H2 = SpinelHttp::Http2Session

# A frame as the client read it. Type TIMED_OUT when nothing came within the
# wait, CLOSED when the server closed the connection (typed sentinels, not
# nil: NOTES.md rule 5).
class H2Frame
  TIMED_OUT = 254
  CLOSED = 255

  attr_reader :frame_type, :frame_flags, :frame_stream, :frame_payload

  def initialize(type, flags, stream, payload)
    @frame_type = type
    @frame_flags = flags
    @frame_stream = stream
    @frame_payload = payload
  end

  def end_stream?
    (@frame_flags & 1) != 0
  end
end

# What one stream got: its status, its header lines ("name: value"), its
# body, and the RST_STREAM code (-1 for none). A connection that ended has
# goaway_code (-1 for none) and closed set.
class H2Result
  attr_accessor :status, :lines, :body, :rst_code, :goaway_code, :closed, :ended, :data_frames

  def initialize
    @status = ""
    @lines = Array.new(0) { "" }
    @body = +""
    @rst_code = -1
    @goaway_code = -1
    @closed = false
    @ended = false
    @data_frames = 0
  end

  def header(name)
    wanted = "#{name}: "
    @lines.each { |l| return l.byteslice(wanted.bytesize, l.bytesize - wanted.bytesize) if l.start_with?(wanted) }
    ""
  end
end

# The main thread shares the scheduler with the server: wait_readable
# before every readpartial (NOTES.md rule 14).
class H2Client
  attr_reader :server_settings, :goaway_code, :finished

  def initialize(port)
    @sock = TCPSocket.new("127.0.0.1", port)
    @buf = +""
    @decoder = SpinelHttp::HpackDecoder.new(4096)
    @encoder = SpinelHttp::HpackEncoder.new
    @server_settings = Array.new(0) { "" }
    @goaway_code = -1
    # the streams in the order their responses ended
    @finished = Array.new(0) { 0 }
    @auto_window = true
  end

  def auto_window=(flag)
    @auto_window = flag
  end

  # The preface and a SETTINGS frame with `settings` (pairs of id, value).
  def open(settings = Array.new(0) { 0 })
    payload = +""
    i = 0
    while i < settings.size
      payload << H2.setting(settings[i], settings[i + 1])
      i += 2
    end
    raw(H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, payload))
  end

  # A write after the server closed is dropped, as a client's would be.
  def raw(bytes)
    @sock.write(bytes)
    nil
  rescue Errno::ECONNRESET, Errno::EPIPE, IOError
    nil
  end

  def frame(type, flags, id, payload)
    raw(H2.frame(type, flags, id, payload))
  end

  # A request's HEADERS: `fields` alternating names and values.
  def headers(id, fields, end_stream)
    frame(H2::HEADERS, (end_stream ? 1 : 0) | 4, id, @encoder.hpack_encode(fields))
  end

  def get(id, path, extra = Array.new(0) { "" })
    fields = [":method", "GET", ":scheme", "http", ":path", path, ":authority", "test"]
    extra.each { |x| fields << x }
    headers(id, fields, true)
  end

  def post(id, path, body)
    headers(id, [":method", "POST", ":scheme", "http", ":path", path, ":authority", "test",
                 "content-type", "text/plain"], false)
    frame(H2::DATA, 1, id, body)
  end

  def next_frame(seconds = 5)
    while @buf.bytesize < 9 || @buf.bytesize < 9 + frame_length
      return H2Frame.new(H2Frame::TIMED_OUT, 0, 0, "") if @sock.wait_readable(seconds).nil?

      begin
        @buf << @sock.readpartial(65_536)
      rescue EOFError, Errno::ECONNRESET
        return H2Frame.new(H2Frame::CLOSED, 0, 0, "")
      end
    end
    len = frame_length
    f = H2Frame.new(@buf.getbyte(3), @buf.getbyte(4), H2.u31(@buf, 5), @buf.byteslice(9, len))
    @buf = @buf.byteslice(9 + len, @buf.bytesize - 9 - len)
    f
  end

  # The results of the streams `ids`, read until each has ended or the
  # connection did; SETTINGS are acknowledged, and DATA is given its window
  # back (unless auto_window is off).
  def collect(ids, seconds = 5)
    results = { 0 => H2Result.new }
    results.delete(0)
    ids.each { |id| results[id] = H2Result.new }
    pending = ids.size
    while pending > 0
      f = next_frame(seconds)
      t = f.frame_type
      if t == H2Frame::TIMED_OUT || t == H2Frame::CLOSED
        results.each_value { |r| r.closed = true if t == H2Frame::CLOSED }
        break
      end
      if t == H2::SETTINGS
        if (f.frame_flags & 1) == 0
          @server_settings << f.frame_payload
          frame(H2::SETTINGS, 1, 0, "")
        end
        next
      end
      if t == H2::GOAWAY
        @goaway_code = H2.u32(f.frame_payload, 4)
        results.each_value { |r| r.goaway_code = @goaway_code }
        next
      end
      r = results[f.frame_stream]
      if t == H2::HEADERS
        block = +""
        block << f.frame_payload
        flags = f.frame_flags
        while (flags & 4) == 0
          c = next_frame(seconds)
          if c.frame_type == H2Frame::TIMED_OUT || c.frame_type == H2Frame::CLOSED
            raise SpinelHttpAssertionFailed, "the header block of stream #{f.frame_stream} did not end"
          end

          block << c.frame_payload
          flags = c.frame_flags
        end
        fields = @decoder.hpack_decode(block, 1_000_000)
        unless r.nil?
          i = 0
          while i < fields.size
            if fields[i] == ":status"
              r.status = fields[i + 1]
            else
              r.lines << "#{fields[i]}: #{fields[i + 1]}"
            end
            i += 2
          end
        end
      elsif t == H2::DATA
        n = f.frame_payload.bytesize
        if @auto_window && n > 0
          frame(H2::WINDOW_UPDATE, 0, 0, H2.u32_bytes(n))
          frame(H2::WINDOW_UPDATE, 0, f.frame_stream, H2.u32_bytes(n)) unless f.end_stream?
        end
        unless r.nil?
          r.body << f.frame_payload
          r.data_frames += 1
        end
      elsif t == H2::RST_STREAM
        r.rst_code = H2.u32(f.frame_payload, 0) unless r.nil?
      end
      next if r.nil? || r.ended

      if (t == H2::HEADERS || t == H2::DATA) && f.end_stream? || t == H2::RST_STREAM
        r.ended = true
        @finished << f.frame_stream
        pending -= 1
      end
    end
    results
  end

  def exchange(id)
    collect([id])[id]
  end

  # Frames until the connection closes or goes quiet; the GOAWAY code, or
  # -1. True in `closed?` once the server closed.
  def until_goaway(seconds = 5)
    while true
      f = next_frame(seconds)
      return -1 if f.frame_type == H2Frame::TIMED_OUT || f.frame_type == H2Frame::CLOSED

      if f.frame_type == H2::GOAWAY
        @goaway_code = H2.u32(f.frame_payload, 4)
        return @goaway_code
      end
    end
  end

  def closed_by_server?(seconds = 5)
    while true
      f = next_frame(seconds)
      return false if f.frame_type == H2Frame::TIMED_OUT
      return true if f.frame_type == H2Frame::CLOSED
    end
  end

  def close
    @sock.close unless @sock.closed?
  end

  private

  def frame_length
    (@buf.getbyte(0) << 16) | (@buf.getbyte(1) << 8) | @buf.getbyte(2)
  end
end

class TwoChunks < SpinelHttp::BodyWriter
  def write_body(sink)
    sink.write("one,")
    sink.write("")
    sink.write("two")
    nil
  end
end

# Writes one event, then waits for the client to go away (a reset stream).
class WaitingWriter < SpinelHttp::BodyWriter
  def write_body(sink)
    sink.write("data: hi\n\n")
    $waiting_closed = sink.wait_closed(5)
    nil
  end
end
$waiting_closed = false

class NoUpgrade < SpinelHttp::BodyWriter
  def write_body(sink)
    sink.write("never")
    nil
  end
end

class H2App < SpinelHttp::HttpHandler
  def call(req)
    res = SpinelHttp::Response.new
    case req.path
    when "/hello"
      res.content_type = "text/plain"
      res.body = "hi"
    when "/echo"
      res.content_type = "text/plain"
      res.set_header("X-Method", req.method)
      res.set_header("X-Version", req.http_version)
      res.set_header("X-Host", req.header("host").to_s)
      res.set_header("X-Cookie", req.header("cookie").to_s)
      res.set_header("X-Query", req.query_string)
      res.set_header("X-Keep-Alive", req.keep_alive? ? "yes" : "no")
      res.body = req.body
    when "/big"
      res.content_type = "text/plain"
      res.body = "a" * req.query_string.to_i
    when "/japanese"
      res.content_type = "text/plain; charset=utf-8"
      res.body = "日本語"
    when "/cookies"
      res.add_cookie("a=1")
      res.add_cookie("b=2")
      res.set_header("Connection", "keep-alive")
      res.body = "c"
    when "/bigheader"
      res.set_header("X-Big", "h" * 20_000)
      res.body = "big header"
    when "/notmodified"
      res.status = 304
      res.body = "never sent"
    when "/nocontent"
      res.status = 204
      res.body = "never sent"
    when "/notmodified_stream"
      res.status = 304
      res.body_writer = TwoChunks.new
    when "/fields"
      res.content_type = "text/plain; charset=utf-8"
      res.set_header("X-Label", " ready\t")
      res.set_header("X-Name", "café")
      res.set_header("TE", "trailers")
      res.body = "é" * 100
    when "/nul"
      res.headers["X-Nul"] = "a" + 0.chr + "b"
      res.body = "never sent"
    when "/stream"
      res.body_writer = TwoChunks.new
    when "/wait"
      res.body_writer = WaitingWriter.new
    when "/upgrade"
      res.upgrade!(NoUpgrade.new)
    when "/inject"
      res.headers["X-Bad"] = "a\r\nInjected: yes"
      res.body = "never sent"
    when "/boom"
      raise "kaboom"
    when "/reject"
      raise SpinelHttp::QueryTooDeep, "nested too deeply (limit 32)"
    when "/slow"
      sleep 0.3
      res.body = "slow"
    else
      res.status = 404
      res.body = "Not Found"
    end
    res
  end
end

$log = StringIO.new

def h2_server(options = {})
  server = SpinelHttp::Server.new(H2App.new, port: 0, logger: TestLog.new($log),
                                  read_timeout: options.fetch(:read_timeout, 5),
                                  body_timeout: options.fetch(:body_timeout, 5.0),
                                  max_body_bytes: options.fetch(:max_body_bytes, 10_485_760),
                                  max_head_bytes: options.fetch(:max_head_bytes, 65_536),
                                  max_streams: options.fetch(:max_streams, 100),
                                  http2: options.fetch(:http2, true))
  server.start
  server
end

def h2_client(server)
  c = H2Client.new(server.port)
  c.open
  c
end

# ---- requests and responses ----

test "a GET over h2c is answered with the status, the default headers and the body" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/hello")
  r = c.exchange(1)
  assert_equal "200", r.status
  assert_equal "hi", r.body
  assert_equal "text/plain", r.header("content-type")
  assert_equal "2", r.header("content-length")
  assert_equal "nosniff", r.header("x-content-type-options")
  assert_equal "SAMEORIGIN", r.header("x-frame-options")
  assert_equal 1, c.server_settings.size
  settings = c.server_settings[0]
  # MAX_CONCURRENT_STREAMS (3) is 100
  assert_equal 3, (settings.getbyte(0) << 8) | settings.getbyte(1)
  assert_equal 100, H2.u32(settings, 2)
  c.close
  server.stop
end

test "the request carries HTTP/2, its method, :authority as Host and its query" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/echo?x=1&y=2")
  r = c.exchange(1)
  assert_equal "HTTP/2", r.header("x-version")
  assert_equal "GET", r.header("x-method")
  assert_equal "test", r.header("x-host")
  assert_equal "x=1&y=2", r.header("x-query")
  assert_equal "yes", r.header("x-keep-alive")
  c.close
  server.stop
end

test "several requests on one connection, and a body in several DATA frames" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/hello")
  assert_equal "hi", c.exchange(1).body
  c.headers(3, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test", "content-length", "11"], false)
  c.frame(H2::DATA, 0, 3, "hello ")
  c.frame(H2::DATA, 1, 3, "world")
  r = c.exchange(3)
  assert_equal "hello world", r.body
  assert_equal "POST", r.header("x-method")
  c.get(5, "/japanese")
  assert_equal "日本語", c.exchange(5).body.force_encoding("UTF-8")
  c.close
  server.stop
end

test "interleaved streams are answered in the order their requests became whole" do
  server = h2_server
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  c.get(3, "/hello")
  c.frame(H2::DATA, 1, 1, "first")
  results = c.collect([1, 3])
  assert_equal "hi", results[3].body
  assert_equal "first", results[1].body
  assert_equal [3, 1], c.finished
  c.close
  server.stop
end

test "a body larger than the window is sent as the client opens it" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/big?200000")
  r = c.exchange(1)
  assert_equal "200", r.status
  assert_equal 200_000, r.body.bytesize
  assert r.data_frames >= 13
  c.close
  server.stop
end

test "a client window of 0 holds the body until WINDOW_UPDATE" do
  server = h2_server
  c = H2Client.new(server.port)
  c.open([H2::SETTINGS_INITIAL_WINDOW_SIZE, 0])
  c.auto_window = false
  c.get(1, "/hello")
  r = c.collect([1], 0.5)[1]
  assert_equal "200", r.status
  assert_equal "", r.body
  refute r.ended
  c.frame(H2::WINDOW_UPDATE, 0, 1, H2.u32_bytes(1))
  c.frame(H2::WINDOW_UPDATE, 0, 1, H2.u32_bytes(1))
  r = c.collect([1])[1]
  assert_equal "hi", r.body
  c.close
  server.stop
end

test "a response header block past the frame size goes out in CONTINUATION" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/bigheader")
  r = c.exchange(1)
  assert_equal 20_000, r.header("x-big").bytesize
  assert_equal "big header", r.body
  c.close
  server.stop
end

test "a request header block in HEADERS and CONTINUATION is read whole" do
  server = h2_server
  c = h2_client(server)
  block = SpinelHttp::HpackEncoder.new.hpack_encode([":method", "GET", ":scheme", "http", ":path", "/echo", ":authority", "split", "x-pad", "p" * 100])
  c.frame(H2::HEADERS, 1, 1, block.byteslice(0, 10))
  c.frame(H2::CONTINUATION, 0, 1, block.byteslice(10, 20))
  c.frame(H2::CONTINUATION, 4, 1, block.byteslice(30, block.bytesize - 30))
  r = c.exchange(1)
  assert_equal "split", r.header("x-host")
  c.close
  server.stop
end

test "HEAD and 304 have headers and no DATA" do
  server = h2_server
  c = h2_client(server)
  c.headers(1, [":method", "HEAD", ":scheme", "http", ":path", "/hello", ":authority", "test"], true)
  r = c.exchange(1)
  assert_equal "200", r.status
  assert_equal "2", r.header("content-length")
  assert_equal 0, r.data_frames
  c.get(3, "/notmodified")
  r = c.exchange(3)
  assert_equal "304", r.status
  assert_equal "", r.header("content-length")
  assert_equal 0, r.data_frames
  c.get(5, "/nocontent")
  r = c.exchange(5)
  assert_equal "204", r.status
  assert_equal "", r.header("content-length")
  assert_equal 0, r.data_frames
  c.get(7, "/notmodified_stream")
  r = c.exchange(7)
  assert_equal "304", r.status
  assert_equal 0, r.data_frames
  c.headers(9, [":method", "HEAD", ":scheme", "http", ":path", "/stream", ":authority", "test"], true)
  r = c.exchange(9)
  assert_equal "200", r.status
  assert_equal "", r.header("content-length")
  assert_equal 0, r.data_frames
  assert_equal 0, r.data_frames
  c.close
  server.stop
end

test "cookies are joined with '; ', set-cookie is one field each, connection-specific fields are dropped" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/echo", ["cookie", "a=1", "cookie", "b=2"])
  assert_equal "a=1; b=2", c.exchange(1).header("x-cookie")
  c.get(3, "/cookies")
  r = c.exchange(3)
  assert_includes r.lines, "set-cookie: a=1"
  assert_includes r.lines, "set-cookie: b=2"
  assert_equal "", r.header("connection")
  c.close
  server.stop
end

test "values are trimmed, te is dropped, and non-ASCII values and bodies are sent as bytes" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/fields")
  r = c.exchange(1)
  assert_equal "200", r.status
  assert_includes r.lines, "x-label: ready"
  assert_equal "", r.header("te")
  assert_equal "café", r.header("x-name").force_encoding("UTF-8")
  assert_equal 200, r.body.bytesize
  assert_equal "200", r.header("content-length")
  c.close
  server.stop
end

test "trailers end a request" do
  server = h2_server
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  c.frame(H2::DATA, 0, 1, "body")
  c.headers(1, ["x-checksum", "abc"], true)
  assert_equal "body", c.exchange(1).body
  c.close
  server.stop
end

test "a padded DATA and a padded, prioritized HEADERS are read" do
  server = h2_server
  c = h2_client(server)
  block = SpinelHttp::HpackEncoder.new.hpack_encode([":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"])
  payload = +""
  payload << 3.chr
  payload << H2.u32_bytes(0)
  payload << 16.chr
  payload << block
  3.times { payload << 0.chr }
  c.frame(H2::HEADERS, 4 | 8 | 32, 1, payload)
  data = +""
  data << 2.chr
  data << "xyz"
  data << 0.chr
  data << 0.chr
  c.frame(H2::DATA, 1 | 8, 1, data)
  assert_equal "xyz", c.exchange(1).body
  c.close
  server.stop
end

# ---- errors the handler raises, and what the server answers itself ----

test "an exception is a 500, a client fault a 400, and the connection stays" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/boom")
  assert_equal "500", c.exchange(1).status
  c.get(3, "/reject")
  assert_equal "400", c.exchange(3).status
  c.get(5, "/inject")
  r = c.exchange(5)
  assert_equal "500", r.status
  assert_equal "", r.header("x-bad")
  assert_equal "Internal Server Error", r.body
  assert_equal r.body.bytesize.to_s, r.header("content-length")
  c.get(7, "/nul")
  r = c.exchange(7)
  assert_equal "500", r.status
  assert_equal "Internal Server Error", r.body
  c.get(9, "/upgrade")
  assert_equal "500", c.exchange(9).status
  c.get(11, "/hello")
  assert_equal "hi", c.exchange(11).body
  assert_logged $log.string, "ERROR", "response not written: an upgrade (101) cannot be answered over HTTP/2"
  c.close
  server.stop
end

test "a content-length over max_body_bytes is 413 and the stream is reset" do
  server = h2_server(max_body_bytes: 10)
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test", "content-length", "11"], false)
  r = c.exchange(1)
  assert_equal "413", r.status
  r = c.collect([1], 1)[1]
  assert_equal 0, r.rst_code
  c.post(3, "/echo", "0123456789A")
  assert_equal "413", c.exchange(3).status
  c.post(5, "/echo", "0123456789")
  assert_equal "0123456789", c.exchange(5).body
  c.close
  server.stop
end

test "a header list over max_head_bytes is 400" do
  server = h2_server(max_head_bytes: 200)
  c = h2_client(server)
  c.get(1, "/hello", ["x-big", "b" * 300])
  assert_equal "400", c.exchange(1).status
  c.get(3, "/hello")
  assert_equal "hi", c.exchange(3).body
  c.close
  server.stop
end

test "malformed requests are reset with PROTOCOL_ERROR" do
  server = h2_server
  c = h2_client(server)
  c.headers(1, [":method", "GET", ":scheme", "http", ":path", "/hello", "X-Upper", "v"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(1).rst_code
  c.headers(3, [":method", "GET", ":scheme", "http", ":path", "/hello", "connection", "keep-alive"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(3).rst_code
  c.headers(5, [":method", "GET", ":scheme", "http"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(5).rst_code
  c.headers(7, ["x-first", "v", ":method", "GET", ":scheme", "http", ":path", "/"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(7).rst_code
  c.headers(9, [":method", "GET", ":scheme", "http", ":path", "/", "te", "gzip"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(9).rst_code
  c.headers(11, [":method", "POST", ":scheme", "http", ":path", "/echo", "content-length", "3"], false)
  c.frame(H2::DATA, 1, 11, "four")
  assert_equal H2::PROTOCOL_ERROR, c.exchange(11).rst_code
  c.headers(13, [":method", "GET", ":scheme", "http", ":path", "/", ":authority", "a", "host", "b"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(13).rst_code
  # a second :method, after an empty first one
  c.headers(17, [":method", "", ":method", "GET", ":scheme", "http", ":path", "/"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(17).rst_code
  # trailers with a connection-specific field
  c.headers(19, [":method", "POST", ":scheme", "http", ":path", "/echo"], false)
  c.frame(H2::DATA, 0, 19, "x")
  c.headers(19, ["connection", "close"], true)
  assert_equal H2::PROTOCOL_ERROR, c.exchange(19).rst_code
  c.get(21, "/hello")
  assert_equal "hi", c.exchange(21).body
  c.close
  server.stop
end

test "streams past max_streams are refused" do
  server = h2_server(max_streams: 1)
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  c.get(3, "/hello")
  assert_equal H2::REFUSED_STREAM, c.exchange(3).rst_code
  c.frame(H2::DATA, 1, 1, "ok")
  assert_equal "ok", c.exchange(1).body
  c.close
  server.stop
end

test "a stream the client resets before its turn is not answered" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/slow")
  c.get(3, "/hello")
  c.frame(H2::RST_STREAM, 0, 3, H2.u32_bytes(H2::CANCEL))
  c.get(5, "/hello")
  results = c.collect([1, 3, 5], 2)
  assert_equal "slow", results[1].body
  refute results[3].ended
  assert_equal "hi", results[5].body
  c.close
  server.stop
end

# ---- connection errors ----

def goaway_for(bytes, options = {})
  server = h2_server(options)
  c = H2Client.new(server.port)
  c.raw(bytes)
  code = c.until_goaway
  closed = c.closed_by_server?
  c.close
  server.stop
  closed ? code : -2
end

test "a first frame that is not SETTINGS is a PROTOCOL_ERROR" do
  assert_equal H2::PROTOCOL_ERROR, goaway_for(H2::PREFACE + H2.frame(H2::PING, 0, 0, "12345678"))
end

test "DATA on stream 0, PUSH_PROMISE and an even stream are PROTOCOL_ERRORs" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  assert_equal H2::PROTOCOL_ERROR, goaway_for(open + H2.frame(H2::DATA, 0, 0, "x"))
  assert_equal H2::PROTOCOL_ERROR, goaway_for(open + H2.frame(H2::PUSH_PROMISE, 4, 1, H2.u32_bytes(2)))
  block = SpinelHttp::HpackEncoder.new.hpack_encode([":method", "GET", ":scheme", "http", ":path", "/"])
  assert_equal H2::PROTOCOL_ERROR, goaway_for(open + H2.frame(H2::HEADERS, 5, 2, block))
end

test "a header block interrupted by another frame is a PROTOCOL_ERROR" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  block = SpinelHttp::HpackEncoder.new.hpack_encode([":method", "GET", ":scheme", "http", ":path", "/"])
  assert_equal H2::PROTOCOL_ERROR, goaway_for(open + H2.frame(H2::HEADERS, 1, 1, block) + H2.frame(H2::PING, 0, 0, "12345678"))
end

test "a broken header block is a COMPRESSION_ERROR" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  assert_equal H2::COMPRESSION_ERROR, goaway_for(open + H2.frame(H2::HEADERS, 5, 1, 0xbe.chr))
end

test "a frame over the frame size and a bad PING are FRAME_SIZE_ERRORs" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  big = +""
  big << 0.chr
  big << 64.chr
  big << 1.chr
  big << 0.chr
  big << 0.chr
  big << H2.u32_bytes(1)
  assert_equal H2::FRAME_SIZE_ERROR, goaway_for(open + big)
  assert_equal H2::FRAME_SIZE_ERROR, goaway_for(open + H2.frame(H2::PING, 0, 0, "1234"))
end

test "a header block past max_head_bytes compressed ends the connection" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  assert_equal H2::ENHANCE_YOUR_CALM, goaway_for(open + H2.frame(H2::HEADERS, 1, 1, "x" * 300) + H2.frame(H2::CONTINUATION, 0, 1, "x" * 300), max_head_bytes: 500)
end

test "a WINDOW_UPDATE past 2^31-1 on the connection is a FLOW_CONTROL_ERROR" do
  open = H2::PREFACE + H2.frame(H2::SETTINGS, 0, 0, "")
  assert_equal H2::FLOW_CONTROL_ERROR, goaway_for(open + H2.frame(H2::WINDOW_UPDATE, 0, 0, H2.u32_bytes(2_147_483_647)))
end

# ---- PING, SETTINGS, idle, stop ----

test "PING is answered with its payload, and SETTINGS with an ACK" do
  server = h2_server
  c = h2_client(server)
  c.frame(H2::PING, 0, 0, "pingpong")
  got_ack = false
  got_ping = false
  6.times do
    f = c.next_frame(2)
    break if f.frame_type == H2Frame::TIMED_OUT

    got_ack = true if f.frame_type == H2::SETTINGS && f.frame_flags == 1
    got_ping = true if f.frame_type == H2::PING && f.frame_flags == 1 && f.frame_payload == "pingpong"
    break if got_ack && got_ping
  end
  assert got_ack
  assert got_ping
  c.close
  server.stop
end

test "an idle connection gets GOAWAY after read_timeout" do
  server = h2_server(read_timeout: 1)
  c = h2_client(server)
  assert_equal H2::NO_ERROR, c.until_goaway(3)
  assert c.closed_by_server?
  c.close
  server.stop
end

test "a body not whole within body_timeout is 408" do
  server = h2_server(body_timeout: 0.5)
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  r = c.exchange(1)
  assert_equal "408", r.status
  c.get(3, "/hello")
  assert_equal "hi", c.exchange(3).body
  c.close
  server.stop
end

test "stop sends GOAWAY to an idle connection, answers the request in flight, and drains" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/hello")
  assert_equal "hi", c.exchange(1).body
  server.stop
  assert_equal H2::NO_ERROR, c.until_goaway(1)
  assert c.closed_by_server?
  assert_equal 0, server.open_connections
  c.close
  server = h2_server
  c = h2_client(server)
  c.get(1, "/slow")
  sleep 0.1
  server.request_stop
  r = c.exchange(1)
  assert_equal "slow", r.body
  server.stop
  assert_equal 0, server.open_connections
  c.close
end

test "past GOAWAY, frames of a stream above its boundary are dropped and the open stream is still answered" do
  server = h2_server
  c = h2_client(server)
  c.headers(1, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  server.request_stop
  # wakes the session, which then sees the stop and sends GOAWAY (last stream 1)
  c.frame(H2::PING, 0, 0, "wake-up!")
  assert_equal H2::NO_ERROR, c.until_goaway(3)
  c.headers(3, [":method", "POST", ":scheme", "http", ":path", "/echo", ":authority", "test"], false)
  c.frame(H2::DATA, 0, 3, "late")
  c.frame(H2::WINDOW_UPDATE, 0, 3, H2.u32_bytes(10))
  c.frame(H2::DATA, 1, 1, "kept")
  r = c.exchange(1)
  assert_equal "kept", r.body
  assert_equal -1, r.goaway_code
  server.stop
  assert_equal 0, server.open_connections
  c.close
end

# ---- streaming ----

test "a BodyWriter streams DATA frames and ends the stream; the connection stays" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/stream")
  r = c.exchange(1)
  assert_equal "200", r.status
  assert_equal "one,two", r.body
  assert_equal "", r.header("content-length")
  c.get(3, "/hello")
  assert_equal "hi", c.exchange(3).body
  c.close
  server.stop
end

test "a writer's wait_closed sees the client reset its stream" do
  server = h2_server
  c = h2_client(server)
  c.get(1, "/wait")
  f = c.next_frame
  f = c.next_frame while f.frame_type != H2::DATA && f.frame_type != H2Frame::TIMED_OUT && f.frame_type != H2Frame::CLOSED
  assert_equal "data: hi\n\n", f.frame_payload
  c.frame(H2::RST_STREAM, 0, 1, H2.u32_bytes(H2::CANCEL))
  c.get(3, "/hello")
  assert_equal "hi", c.exchange(3).body
  assert $waiting_closed
  c.close
  server.stop
end

# ---- HTTP/1.1 beside it ----

test "HTTP/1.1 is served as before on a server with http2" do
  server = h2_server
  s = TCPSocket.new("127.0.0.1", server.port)
  s.write("GET /hello HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
  out = +""
  while true
    break if s.wait_readable(5).nil?

    begin
      out << s.readpartial(4096)
    rescue EOFError
      break
    end
  end
  assert out.start_with?("HTTP/1.1 200 OK\r\n")
  assert out.end_with?("\r\n\r\nhi")
  s.close
  server.stop
end

test "with http2: false the preface is a 400" do
  server = h2_server(http2: false)
  s = TCPSocket.new("127.0.0.1", server.port)
  s.write(H2::PREFACE)
  out = +""
  while true
    break if s.wait_readable(5).nil?

    begin
      out << s.readpartial(4096)
    rescue EOFError
      break
    end
  end
  assert out.start_with?("HTTP/1.1 400 Bad Request\r\n")
  s.close
  server.stop
end

SpinelHttpTest.summary
