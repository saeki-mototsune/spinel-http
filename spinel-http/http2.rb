require "socket"
require "spinel-http/hpack"
require "spinel-http/parser"
require "spinel-http/request"
require "spinel-http/response"
require "spinel-http/body_writer"
require "spinel-http/log"

module SpinelHttp
  # A connection error (RFC 9113 section 5.4.1): the session answers GOAWAY
  # with #h2_code and closes the connection.
  class Http2Error < StandardError
    attr_reader :h2_code

    def initialize(code, message)
      super(message)
      @h2_code = code
    end
  end

  # The connection cannot be written to any more (a write past
  # stream_write_timeout, a peer gone): the session ends without GOAWAY.
  class Http2Closed < StandardError
  end

  # The limits the Server hands each HTTP/2 session, taken from its own
  # options (Server.new): built once, so a session reads them without the
  # Server growing a reader per option. The `h2_` prefix keeps the names
  # off an application's (NOTES.md rule 6).
  class Http2Limits
    attr_reader :h2_read_wait, :h2_head_timeout, :h2_body_timeout, :h2_max_head_bytes,
                :h2_max_body_bytes, :h2_write_timeout, :h2_max_streams

    def initialize(read_wait, head_timeout, body_timeout, max_head_bytes, max_body_bytes, write_timeout, max_streams)
      @h2_read_wait = read_wait
      @h2_head_timeout = head_timeout
      @h2_body_timeout = body_timeout
      @h2_max_head_bytes = max_head_bytes
      @h2_max_body_bytes = max_body_bytes
      @h2_write_timeout = write_timeout
      @h2_max_streams = max_streams
    end
  end

  # One request stream of an HTTP/2 connection, from its HEADERS until its
  # response has been sent (or it was reset).
  class Http2Stream
    # Receiving the request.
    OPEN = 1
    # The request is whole (END_STREAM seen); waiting for or sending the
    # response.
    HALF_CLOSED = 2

    attr_reader :h2_id
    attr_accessor :h2_state, :h2_method, :h2_path, :h2_headers, :h2_body, :h2_content_length,
                  :h2_received, :h2_send_window, :h2_recv_window, :h2_deadline, :h2_reject_status,
                  :h2_reset

    def initialize(id, send_window, recv_window)
      @h2_id = id
      @h2_state = OPEN
      @h2_method = ""
      @h2_path = ""
      @h2_headers = { "" => "" }
      @h2_headers.delete("")
      @h2_body = +""
      # -1 when the request has no content-length
      @h2_content_length = -1
      @h2_received = 0
      @h2_send_window = send_window
      @h2_recv_window = recv_window
      # 0.0 when no deadline runs (the request is whole)
      @h2_deadline = 0.0
      # 0, or the status the server answers itself (413, 408, 400)
      @h2_reject_status = 0
      # the client reset it, or the server did
      @h2_reset = false
    end
  end

  # The {Sink} of a streaming response over HTTP/2: #write sends DATA frames
  # on the response's stream, within the flow-control windows; #wait_closed
  # reads the connection's frames for up to `seconds` and is true once the
  # client reset the stream or the connection ended. #socket is the
  # connection's socket, shared by every stream on it: a writer must not
  # speak its own protocol on it (there is no 101 upgrade over HTTP/2).
  # @api public
  class Http2Sink < Sink
    def initialize(session, stream_id, socket, write_timeout)
      super(socket, false, write_timeout)
      @session = session
      @stream_id = stream_id
    end

    # Sends `bytes` as DATA on the stream; "" sends nothing. Never raises.
    # @param bytes [String]
    # @return [nil]
    def write(bytes)
      return nil if @closed

      data = bytes.to_s # NOTES.md rule 3
      return nil if data.bytesize == 0

      unless @session.h2_stream_data(@stream_id, data)
        @closed = true
        @broken = true
      end
      nil
    end

    # @param seconds [Numeric]
    # @return [Boolean]
    def wait_closed(seconds)
      return true if @closed

      @closed = true if @session.h2_stream_gone?(@stream_id, seconds.to_f)
      @closed
    end

    # The end of the body: an empty DATA frame with END_STREAM.
    def sink_finish
      return nil if @broken

      @session.h2_stream_finish(@stream_id)
      nil
    end
  end

  # One HTTP/2 connection (RFC 9113) over cleartext TCP, the client having
  # opened it with the connection preface (prior knowledge, "h2c"). The
  # Server hands the connection over once it has read the preface; the
  # session sends its SETTINGS, reads frames, and answers each request on
  # this one thread, in the order the requests became whole: a response is
  # written before the next request is handled, while frames that arrive
  # meanwhile (new requests, WINDOW_UPDATE, PING, RST_STREAM) are read and
  # acted on. No lock and no thread per stream (NOTES.md rule 15).
  #
  # Limits: at most `max_streams` streams open at once (more are refused
  # with REFUSED_STREAM); a header block at most max_head_bytes compressed
  # and as a header list (400 past it); a body at most max_body_bytes (413);
  # the bodies buffered for requests not yet handled at most max_body_bytes
  # together (the connection window is not reopened past that until a
  # request is handled); a frame, and a header block with its
  # CONTINUATIONs, whole within head_timeout of its first byte; a body
  # within body_timeout of its HEADERS (408); a write within
  # stream_write_timeout; an idle connection closed after read_timeout.
  # @api private
  class Http2Session
    PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    DATA = 0
    HEADERS = 1
    PRIORITY = 2
    RST_STREAM = 3
    SETTINGS = 4
    PUSH_PROMISE = 5
    PING = 6
    GOAWAY = 7
    WINDOW_UPDATE = 8
    CONTINUATION = 9

    FLAG_END_STREAM = 1
    FLAG_ACK = 1
    FLAG_END_HEADERS = 4
    FLAG_PADDED = 8
    FLAG_PRIORITY = 32

    NO_ERROR = 0
    PROTOCOL_ERROR = 1
    INTERNAL_ERROR = 2
    FLOW_CONTROL_ERROR = 3
    SETTINGS_TIMEOUT = 4
    STREAM_CLOSED = 5
    FRAME_SIZE_ERROR = 6
    REFUSED_STREAM = 7
    CANCEL = 8
    COMPRESSION_ERROR = 9
    ENHANCE_YOUR_CALM = 11

    SETTINGS_HEADER_TABLE_SIZE = 1
    SETTINGS_ENABLE_PUSH = 2
    SETTINGS_MAX_CONCURRENT_STREAMS = 3
    SETTINGS_INITIAL_WINDOW_SIZE = 4
    SETTINGS_MAX_FRAME_SIZE = 5
    SETTINGS_MAX_HEADER_LIST_SIZE = 6

    # The frame size this server accepts (the protocol's default; it does
    # not advertise a larger one) and the window size both sides start
    # with.
    MAX_FRAME = 16_384
    DEFAULT_WINDOW = 65_535
    MAX_WINDOW = 2_147_483_647
    READ_CHUNK = 16_384

    # Request header fields HTTP/2 forbids (RFC 9113 section 8.2.2); `te`
    # is allowed only as "trailers".
    CONNECTION_FIELDS = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"]

    def initialize(server, sock, conn, remote_addr, rest, limits)
      @server = server
      @sock = sock
      @conn = conn
      @remote_addr = remote_addr
      @limits = limits
      @logger = server.h2_logger
      @buf = +""
      @buf << rest
      @rpos = 0
      @decoder = HpackDecoder.new(4096)
      @encoder = HpackEncoder.new
      @streams = { 0 => Http2Stream.new(0, 0, 0) }
      @streams.delete(0)
      @ready = Array.new(0) { 0 }
      @last_stream_id = 0
      @peer_initial_window = DEFAULT_WINDOW
      @peer_max_frame = MAX_FRAME
      @send_window = DEFAULT_WINDOW
      @recv_window = DEFAULT_WINDOW
      # body bytes held for requests not yet handled, and the connection
      # window held back while they are over max_body_bytes
      @buffered = 0
      @owed = 0
      @goaway_sent = false
      @peer_goaway = false
      @settings_seen = false
      # the frame being read: 0.0 until its first byte is here
      @frame_deadline = 0.0
      # a header block waiting for CONTINUATION: its stream (0 for none)
      @block_stream = 0
      @block = +""
      @block_end_stream = false
      @block_deadline = 0.0
      # the frame just taken off the buffer
      @f_type = 0
      @f_flags = 0
      @f_stream = 0
      @f_payload = ""
      @fields_refused = false
    end

    # Serves the connection until it ends. The rescue arms are here, in a
    # method that takes no block (NOTES.md rule 11); EOFError and the
    # socket errors go on to Server#serve, which closes quietly.
    def h2_serve
      h2_serve_frames
      h2_linger if @goaway_sent
      nil
    end

    # How long the end of a connection that sent GOAWAY reads and drops
    # what the client still sends, at most.
    LINGER = 1.0

    private

    def h2_serve_frames
      h2_run
      nil
    rescue Http2Error => e
      h2_goaway_quietly(e.h2_code, e.message)
      nil
    rescue HpackError => e
      h2_goaway_quietly(COMPRESSION_ERROR, e.message)
      nil
    rescue Http2Closed
      @goaway_sent = false
      nil
    end

    # After GOAWAY: the write side is shut and what the client still sends
    # (a SETTINGS ACK, a WINDOW_UPDATE for the last DATA) is read and
    # dropped until it closes, LINGER at most. Closing a socket with unread
    # bytes would send a reset, and a client may then drop the response it
    # has not read yet.
    def h2_linger
      sock = @sock
      sock.shutdown(Socket::SHUT_WR)
      deadline = h2_now + LINGER
      while true
        left = deadline - h2_now
        break if left <= 0.0 || sock.wait_readable(left).nil?

        sock.readpartial(READ_CHUNK)
      end
      nil
    rescue EOFError, IOError, SystemCallError
      nil
    end

    public

    # Sends DATA on stream `id` for a streaming response (Http2Sink#write);
    # false once the stream or the connection is gone.
    def h2_stream_data(id, data)
      stream = @streams[id]
      return false if stream.nil? || stream.h2_reset

      h2_send_data(stream, data, false)
    rescue Http2Error => e
      h2_goaway_quietly(e.h2_code, e.message)
      false
    rescue HpackError => e
      h2_goaway_quietly(COMPRESSION_ERROR, e.message)
      false
    rescue Http2Closed, IOError, SystemCallError
      @goaway_sent = true
      false
    end

    # Ends stream `id`'s body (Http2Sink#sink_finish).
    def h2_stream_finish(id)
      stream = @streams[id]
      return nil if stream.nil? || stream.h2_reset

      h2_send_data(stream, "", true)
      nil
    rescue Http2Error, HpackError, Http2Closed, IOError, SystemCallError
      @goaway_sent = true
      nil
    end

    # Reads the connection's frames for up to `seconds`; true once stream
    # `id` was reset or the connection ended (Http2Sink#wait_closed).
    def h2_stream_gone?(id, seconds)
      deadline = h2_now + seconds
      while true
        h2_process_buffered
        stream = @streams[id]
        return true if stream.nil? || stream.h2_reset || @goaway_sent

        left = deadline - h2_now
        return false if left <= 0.0

        wait = h2_bounded(left)
        # a wait cut short by a head deadline loops: h2_process_buffered
        # then refuses the frame or the block
        return false unless h2_fill(wait) || wait < left
      end
    rescue Http2Error => e
      h2_goaway_quietly(e.h2_code, e.message)
      true
    rescue HpackError => e
      h2_goaway_quietly(COMPRESSION_ERROR, e.message)
      true
    rescue Http2Closed, EOFError, IOError, SystemCallError
      @goaway_sent = true
      true
    end

    private

    def h2_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The loop: act on every whole frame buffered, then answer one request
    # that is ready, then wait for more bytes.
    def h2_run
      h2_send_settings
      while true
        h2_process_buffered
        return if @goaway_sent && @streams.empty?

        unless @ready.empty?
          h2_dispatch(@ready.shift)
          next
        end
        unless @server.h2_running?
          # Stopping: GOAWAY with the last stream taken, then the streams
          # still open are answered and the connection ends.
          h2_goaway(NO_ERROR, "") unless @goaway_sent
          return if @streams.empty?
        end
        return if @peer_goaway && @streams.empty?
        return unless h2_wait
      end
    end

    # Acts on each whole frame in the buffer. A frame or a header block past
    # head_timeout is refused here too, so the reads made while a response
    # is written (waiting for WINDOW_UPDATE, Http2Sink#wait_closed) keep the
    # deadlines that h2_wait keeps.
    def h2_process_buffered
      h2_check_head_deadlines
      while h2_take_frame
        h2_frame
        h2_check_head_deadlines
      end
      nil
    end

    def h2_check_head_deadlines
      return nil if @block_stream == 0 && @frame_deadline == 0.0

      now = h2_now
      raise Http2Error.new(ENHANCE_YOUR_CALM, "header block not whole within head_timeout") if @block_stream != 0 && now >= @block_deadline
      raise Http2Error.new(ENHANCE_YOUR_CALM, "frame not whole within head_timeout") if @frame_deadline > 0.0 && now >= @frame_deadline

      nil
    end

    # Waits for more bytes; false when the connection should end quietly
    # (idle past read_timeout, or silent mid-request past it).
    def h2_wait
      now = h2_now
      partial = @buf.bytesize > @rpos
      if partial || @block_stream != 0
        @frame_deadline = now + @limits.h2_head_timeout if partial && @frame_deadline == 0.0
        deadline = @block_stream != 0 ? @block_deadline : @frame_deadline
        deadline = @frame_deadline if partial && @frame_deadline < deadline
        left = deadline - now
        raise Http2Error.new(ENHANCE_YOUR_CALM, "frame not whole within head_timeout") if left <= 0.0

        return h2_fill(left < @limits.h2_read_wait ? left : @limits.h2_read_wait) || h2_timed_out(deadline)
      end
      stream_deadline = h2_next_deadline
      if stream_deadline > 0.0
        left = stream_deadline - now
        if left <= 0.0
          h2_expire_streams
          return true
        end
        return true if h2_fill(left < @limits.h2_read_wait ? left : @limits.h2_read_wait)
        return true if h2_now >= stream_deadline && h2_expire_streams

        return false
      end
      return false if @streams.empty? && @goaway_sent

      # Idle: marked for the drain, which ends the wait when the server
      # stops (Server#shut_idle_connections).
      @conn.idle = true
      ready = (@server.h2_running? || @conn.awaiting_first_request) && h2_idle_fill
      @conn.idle = false
      h2_goaway(NO_ERROR, "") unless ready || @goaway_sent
      ready
    end

    # The idle wait. The drain ends it by shutting the read side, which
    # reads as EOF: with the server stopping, that is the stop, answered
    # with GOAWAY while the write side is still open (false); with the
    # server running, the client went away, and the EOF goes on to
    # Server#serve, which closes quietly.
    def h2_idle_fill
      h2_fill(@limits.h2_read_wait)
    rescue EOFError
      raise if @server.h2_running?

      false
    end

    # A wait for a frame or a header block that ran out: past its deadline
    # it is a connection error, else (read_timeout) the end.
    def h2_timed_out(deadline)
      raise Http2Error.new(ENHANCE_YOUR_CALM, "frame not whole within head_timeout") if h2_now >= deadline

      false
    end

    # Reads what the socket has within `seconds`; false when nothing came.
    # wait_readable before readpartial (NOTES.md rule 14).
    def h2_fill(seconds)
      return false if @sock.wait_readable(seconds).nil?

      if @rpos > 0 && @rpos >= @buf.bytesize
        @buf = +""
        @rpos = 0
      elsif @rpos > 65_536
        rest = @buf.byteslice(@rpos, @buf.bytesize - @rpos)
        @buf = +""
        @buf << rest
        @rpos = 0
      end
      @buf << @sock.readpartial(READ_CHUNK)
      # the first bytes of a frame start its head_timeout, whichever read
      # took them in (h2_wait, or one made while a response is written)
      @frame_deadline = h2_now + @limits.h2_head_timeout if @frame_deadline == 0.0 && @buf.bytesize > @rpos
      true
    end

    # `left` seconds, or less when a frame or a header block that has begun
    # must be whole sooner: the reads made while a response is written wait
    # no longer than head_timeout allows.
    def h2_bounded(left)
      wait = left
      if @block_stream != 0
        d = @block_deadline - h2_now
        wait = d if d < wait
      end
      if @frame_deadline > 0.0
        d = @frame_deadline - h2_now
        wait = d if d < wait
      end
      wait < 0.0 ? 0.0 : wait
    end

    # The earliest deadline of a stream still receiving its body, 0.0 when
    # none runs.
    def h2_next_deadline
      earliest = 0.0
      @streams.each_value do |s|
        d = s.h2_deadline
        earliest = d if d > 0.0 && (earliest == 0.0 || d < earliest)
      end
      earliest
    end

    # Answers 408 on every stream whose body is past body_timeout. True when
    # one was.
    def h2_expire_streams
      now = h2_now
      expired = Array.new(0) { 0 }
      @streams.each_value do |s|
        expired << s.h2_id if s.h2_deadline > 0.0 && now >= s.h2_deadline
      end
      expired.each { |id| h2_reject(@streams[id], 408) }
      !expired.empty?
    end

    # Takes the next whole frame off the buffer into @f_*; false when the
    # buffer holds none yet.
    def h2_take_frame
      avail = @buf.bytesize - @rpos
      return false if avail < 9

      s = @buf
      p = @rpos
      len = (s.getbyte(p) << 16) | (s.getbyte(p + 1) << 8) | s.getbyte(p + 2)
      raise Http2Error.new(FRAME_SIZE_ERROR, "frame of #{len} bytes over #{MAX_FRAME}") if len > MAX_FRAME
      return false if avail < 9 + len

      @f_type = s.getbyte(p + 3)
      @f_flags = s.getbyte(p + 4)
      @f_stream = Http2Session.u31(s, p + 5)
      @f_payload = len == 0 ? "" : s.byteslice(p + 9, len)
      @rpos = p + 9 + len
      @frame_deadline = 0.0
      @frame_deadline = h2_now + @limits.h2_head_timeout if @buf.bytesize > @rpos
      true
    end

    # Acts on the frame in @f_*.
    def h2_frame
      type = @f_type
      unless @settings_seen
        raise Http2Error.new(PROTOCOL_ERROR, "the preface must be followed by SETTINGS") if type != SETTINGS

        @settings_seen = true
      end
      if @block_stream != 0 && type != CONTINUATION
        raise Http2Error.new(PROTOCOL_ERROR, "a header block was interrupted")
      end

      case type
      when DATA then h2_on_data
      when HEADERS then h2_on_headers
      when PRIORITY then h2_on_priority
      when RST_STREAM then h2_on_rst_stream
      when SETTINGS then h2_on_settings
      when PUSH_PROMISE
        raise Http2Error.new(PROTOCOL_ERROR, "a client must not send PUSH_PROMISE")
      when PING then h2_on_ping
      when GOAWAY then h2_on_goaway
      when WINDOW_UPDATE then h2_on_window_update
      when CONTINUATION then h2_on_continuation
      end
      # any other type is ignored (RFC 9113 section 4.1)
      nil
    end

    # --- frames ---------------------------------------------------------

    def h2_on_data
      id = @f_stream
      raise Http2Error.new(PROTOCOL_ERROR, "DATA on stream 0") if id == 0

      payload = @f_payload
      len = payload.bytesize
      @recv_window -= len
      raise Http2Error.new(FLOW_CONTROL_ERROR, "DATA past the connection window") if @recv_window < 0

      stream = @streams[id]
      if stream.nil?
        # past a GOAWAY a stream above its boundary was never taken: what
        # is in flight for it is dropped (section 6.8), not an error
        raise Http2Error.new(PROTOCOL_ERROR, "DATA on idle stream #{id}") if id > @last_stream_id && !@goaway_sent

        # a stream already answered or reset: dropped (section 5.1)
        h2_credit_connection(len)
        return nil
      end
      if stream.h2_state != Http2Stream::OPEN
        h2_credit_connection(len)
        h2_reset(id, STREAM_CLOSED)
        return nil
      end
      stream.h2_recv_window -= len
      if stream.h2_recv_window < 0
        h2_credit_connection(len)
        h2_reset(id, FLOW_CONTROL_ERROR)
        return nil
      end
      data = h2_unpad(payload, @f_flags)
      end_stream = (@f_flags & FLAG_END_STREAM) != 0
      if stream.h2_reject_status != 0
        # already refused (413): what follows is read and dropped
        h2_credit_connection(len)
        stream.h2_state = Http2Stream::HALF_CLOSED if end_stream
        return nil
      end
      stream.h2_received += data.bytesize
      if stream.h2_received > @limits.h2_max_body_bytes
        h2_credit_connection(len)
        h2_release_body(stream)
        stream.h2_state = Http2Stream::HALF_CLOSED if end_stream
        h2_reject(stream, 413)
        return nil
      end
      if stream.h2_content_length >= 0 && stream.h2_received > stream.h2_content_length
        h2_credit_connection(len)
        h2_reset(id, PROTOCOL_ERROR)
        return nil
      end
      stream.h2_body << data
      @buffered += data.bytesize
      # padding is credited at once; the data once there is room for it
      h2_credit_connection(len - data.bytesize)
      if @buffered <= @limits.h2_max_body_bytes
        h2_credit_connection(data.bytesize)
      else
        @owed += data.bytesize
      end
      if end_stream
        if stream.h2_content_length >= 0 && stream.h2_received != stream.h2_content_length
          h2_reset(id, PROTOCOL_ERROR)
          return nil
        end
        h2_request_whole(stream)
      elsif len > 0
        stream.h2_recv_window += len
        h2_send_window_update(id, len)
      end
      nil
    end

    def h2_on_headers
      id = @f_stream
      raise Http2Error.new(PROTOCOL_ERROR, "HEADERS on stream 0") if id == 0

      payload = @f_payload
      flags = @f_flags
      pos = 0
      pad = 0
      if (flags & FLAG_PADDED) != 0
        raise Http2Error.new(PROTOCOL_ERROR, "HEADERS too short for its padding") if payload.bytesize < 1

        pad = payload.getbyte(0)
        pos = 1
      end
      if (flags & FLAG_PRIORITY) != 0
        raise Http2Error.new(PROTOCOL_ERROR, "HEADERS too short for its priority") if payload.bytesize < pos + 5

        dependency = Http2Session.u31(payload, pos)
        pos += 5
        if dependency == id
          h2_drop_block(id, payload, pos, pad, flags)
          return nil
        end
      end
      raise Http2Error.new(PROTOCOL_ERROR, "HEADERS padding past the frame") if pos + pad > payload.bytesize

      fragment = payload.byteslice(pos, payload.bytesize - pos - pad)
      end_stream = (flags & FLAG_END_STREAM) != 0
      if (flags & FLAG_END_HEADERS) != 0
        # one frame is at most MAX_FRAME; its list is held to
        # max_head_bytes by the decoder (a 400)
        h2_header_block(id, fragment, end_stream)
      else
        @block_stream = id
        @block = +""
        @block << fragment
        @block_end_stream = end_stream
        @block_deadline = h2_now + @limits.h2_head_timeout
        h2_check_block_size
      end
      nil
    end

    # A HEADERS frame whose stream depends on itself: a stream error
    # (section 5.3.1), but its block is still decoded to keep the table in
    # step, once whole.
    def h2_drop_block(id, payload, pos, pad, flags)
      raise Http2Error.new(PROTOCOL_ERROR, "HEADERS padding past the frame") if pos + pad > payload.bytesize

      raise Http2Error.new(PROTOCOL_ERROR, "a stream that depends on itself must not continue") if (flags & FLAG_END_HEADERS) == 0

      @decoder.hpack_decode(payload.byteslice(pos, payload.bytesize - pos - pad), @limits.h2_max_head_bytes)
      @last_stream_id = id if id > @last_stream_id && (id & 1) == 1 && !@goaway_sent
      h2_reset(id, PROTOCOL_ERROR)
      nil
    end

    def h2_on_continuation
      id = @f_stream
      raise Http2Error.new(PROTOCOL_ERROR, "CONTINUATION without HEADERS") if @block_stream == 0 || id != @block_stream

      @block << @f_payload
      h2_check_block_size
      return nil if (@f_flags & FLAG_END_HEADERS) == 0

      block = @block
      @block = +""
      @block_stream = 0
      @block_deadline = 0.0
      h2_header_block(id, block, @block_end_stream)
      nil
    end

    # A header block past max_head_bytes compressed cannot be skipped (the
    # table would fall out of step), so the connection ends.
    def h2_check_block_size
      return nil if @block.bytesize <= @limits.h2_max_head_bytes

      raise Http2Error.new(ENHANCE_YOUR_CALM, "header block over max_head_bytes")
    end

    # A whole header block for stream `id`: a new request, or the trailers
    # of an open one.
    def h2_header_block(id, block, end_stream)
      fields = @decoder.hpack_decode(block, @limits.h2_max_head_bytes)
      stream = @streams[id]
      unless stream.nil?
        # trailers: they end the request and are dropped
        if stream.h2_state != Http2Stream::OPEN
          h2_reset(id, STREAM_CLOSED) unless stream.h2_reset
          return nil
        end
        unless end_stream && !@decoder.hpack_oversized? && Http2Session.trailers_valid?(fields)
          h2_reset(id, PROTOCOL_ERROR)
          return nil
        end
        if stream.h2_reject_status != 0
          stream.h2_state = Http2Stream::HALF_CLOSED
          return nil
        end
        if stream.h2_content_length >= 0 && stream.h2_received != stream.h2_content_length
          h2_reset(id, PROTOCOL_ERROR)
          return nil
        end
        h2_request_whole(stream)
        return nil
      end
      raise Http2Error.new(PROTOCOL_ERROR, "stream #{id} is a server's") if (id & 1) == 0
      # a stream already answered or reset: dropped (section 5.1)
      return nil if id <= @last_stream_id
      # past a GOAWAY new streams are not processed (section 6.8), and the
      # last stream id it named stays the boundary
      return nil if @goaway_sent

      @last_stream_id = id

      if @streams.size >= @limits.h2_max_streams
        h2_send_rst(id, REFUSED_STREAM)
        return nil
      end
      stream = Http2Stream.new(id, @peer_initial_window, DEFAULT_WINDOW)
      @streams[id] = stream
      if @decoder.hpack_oversized?
        stream.h2_state = Http2Stream::HALF_CLOSED if end_stream
        h2_reject(stream, 400)
        return nil
      end
      unless h2_take_request_fields(stream, fields)
        h2_reset(id, PROTOCOL_ERROR)
        return nil
      end
      if stream.h2_content_length > @limits.h2_max_body_bytes
        stream.h2_state = Http2Stream::HALF_CLOSED if end_stream
        h2_reject(stream, 413)
        return nil
      end
      if end_stream
        if stream.h2_content_length > 0
          h2_reset(id, PROTOCOL_ERROR)
          return nil
        end
        h2_request_whole(stream)
      else
        stream.h2_deadline = h2_now + @limits.h2_body_timeout
      end
      nil
    end

    def h2_on_priority
      raise Http2Error.new(PROTOCOL_ERROR, "PRIORITY on stream 0") if @f_stream == 0

      if @f_payload.bytesize != 5
        h2_send_rst(@f_stream, FRAME_SIZE_ERROR)
        return nil
      end
      # priorities are not acted on (RFC 9113 deprecates the scheme)
      nil
    end

    def h2_on_rst_stream
      id = @f_stream
      raise Http2Error.new(PROTOCOL_ERROR, "RST_STREAM on stream 0") if id == 0
      raise Http2Error.new(FRAME_SIZE_ERROR, "RST_STREAM of #{@f_payload.bytesize} bytes") if @f_payload.bytesize != 4
      raise Http2Error.new(PROTOCOL_ERROR, "RST_STREAM on idle stream #{id}") if id > @last_stream_id && !@goaway_sent

      stream = @streams[id]
      return nil if stream.nil?

      stream.h2_reset = true
      h2_forget(stream)
      nil
    end

    def h2_on_settings
      raise Http2Error.new(PROTOCOL_ERROR, "SETTINGS on a stream") if @f_stream != 0

      payload = @f_payload
      if (@f_flags & FLAG_ACK) != 0
        raise Http2Error.new(FRAME_SIZE_ERROR, "SETTINGS ACK with a payload") if payload.bytesize != 0

        return nil
      end
      raise Http2Error.new(FRAME_SIZE_ERROR, "SETTINGS of #{payload.bytesize} bytes") if payload.bytesize % 6 != 0

      pos = 0
      while pos < payload.bytesize
        key = (payload.getbyte(pos) << 8) | payload.getbyte(pos + 1)
        value = Http2Session.u32(payload, pos + 2)
        pos += 6
        case key
        when SETTINGS_HEADER_TABLE_SIZE
          @encoder.hpack_table_size_changed
        when SETTINGS_ENABLE_PUSH
          raise Http2Error.new(PROTOCOL_ERROR, "ENABLE_PUSH of #{value}") if value > 1
        when SETTINGS_INITIAL_WINDOW_SIZE
          raise Http2Error.new(FLOW_CONTROL_ERROR, "INITIAL_WINDOW_SIZE of #{value}") if value > MAX_WINDOW

          h2_new_initial_window(value)
        when SETTINGS_MAX_FRAME_SIZE
          raise Http2Error.new(PROTOCOL_ERROR, "MAX_FRAME_SIZE of #{value}") if value < 16_384 || value > 16_777_215

          @peer_max_frame = value
        end
      end
      h2_write(Http2Session.frame(SETTINGS, FLAG_ACK, 0, ""))
      nil
    end

    # Section 6.9.2: a new initial window changes every stream's window by
    # the difference.
    def h2_new_initial_window(value)
      delta = value - @peer_initial_window
      @peer_initial_window = value
      @streams.each_value do |s|
        s.h2_send_window += delta
        raise Http2Error.new(FLOW_CONTROL_ERROR, "a stream window past 2^31-1") if s.h2_send_window > MAX_WINDOW
      end
      nil
    end

    def h2_on_ping
      raise Http2Error.new(PROTOCOL_ERROR, "PING on a stream") if @f_stream != 0
      raise Http2Error.new(FRAME_SIZE_ERROR, "PING of #{@f_payload.bytesize} bytes") if @f_payload.bytesize != 8
      return nil if (@f_flags & FLAG_ACK) != 0

      h2_write(Http2Session.frame(PING, FLAG_ACK, 0, @f_payload))
      nil
    end

    def h2_on_goaway
      raise Http2Error.new(PROTOCOL_ERROR, "GOAWAY on a stream") if @f_stream != 0
      raise Http2Error.new(FRAME_SIZE_ERROR, "GOAWAY of #{@f_payload.bytesize} bytes") if @f_payload.bytesize < 8

      @peer_goaway = true
      nil
    end

    def h2_on_window_update
      raise Http2Error.new(FRAME_SIZE_ERROR, "WINDOW_UPDATE of #{@f_payload.bytesize} bytes") if @f_payload.bytesize != 4

      increment = Http2Session.u31(@f_payload, 0)
      id = @f_stream
      if id == 0
        raise Http2Error.new(PROTOCOL_ERROR, "WINDOW_UPDATE of 0") if increment == 0

        @send_window += increment
        raise Http2Error.new(FLOW_CONTROL_ERROR, "the connection window past 2^31-1") if @send_window > MAX_WINDOW

        return nil
      end
      stream = @streams[id]
      if stream.nil?
        raise Http2Error.new(PROTOCOL_ERROR, "WINDOW_UPDATE on idle stream #{id}") if id > @last_stream_id && !@goaway_sent

        return nil
      end
      if increment == 0
        h2_reset(id, PROTOCOL_ERROR)
        return nil
      end
      stream.h2_send_window += increment
      h2_reset(id, FLOW_CONTROL_ERROR) if stream.h2_send_window > MAX_WINDOW
      nil
    end

    # --- requests ---------------------------------------------------------

    # Checks a request's header list (RFC 9113 section 8.2 and 8.3) and
    # keeps its parts on `stream`; false for a malformed request, which the
    # caller resets with PROTOCOL_ERROR.
    def h2_take_request_fields(stream, fields)
      headers = stream.h2_headers
      cookies = Array.new(0) { "" }
      method = ""
      scheme = ""
      authority = ""
      path = ""
      has_authority = false
      seen = 0
      regular = false
      i = 0
      while i < fields.size
        name = fields[i]
        value = fields[i + 1]
        i += 2
        return false unless Http2Session.field_name?(name) && Http2Session.field_value?(value)

        if name.start_with?(":")
          return false if regular

          # `seen`: a bit per pseudo-header, so a second one is refused
          # even when the first was empty
          bit = 0
          case name
          when ":method"
            bit = 1
            method = value
          when ":scheme"
            bit = 2
            scheme = value
          when ":path"
            bit = 4
            path = value
          when ":authority"
            bit = 8
            has_authority = true
            authority = value
          else
            return false
          end
          return false if (seen & bit) != 0

          seen |= bit
          next
        end
        regular = true
        return false if CONNECTION_FIELDS.include?(name)
        return false if name == "te" && value != "trailers"

        if name == "cookie"
          cookies << value
          next
        end
        existing = headers[name]
        headers[name] = existing.nil? ? value : "#{existing}, #{value}"
      end
      # CONNECT (no :scheme and :path) is not served.
      return false if method.empty? || scheme.empty? || path.empty?

      headers["cookie"] = cookies.join("; ") unless cookies.empty?
      host = headers["host"]
      if host.nil?
        headers["host"] = authority if has_authority && !authority.empty?
      elsif has_authority && host != authority
        return false
      end
      length = headers["content-length"]
      unless length.nil?
        stream.h2_content_length = Http2Session.content_length_of(length, @limits.h2_max_body_bytes)
        return false if stream.h2_content_length < 0
      end
      stream.h2_method = method
      stream.h2_path = path
      true
    end

    # The request on `stream` is whole: it waits its turn.
    def h2_request_whole(stream)
      stream.h2_state = Http2Stream::HALF_CLOSED
      stream.h2_deadline = 0.0
      @ready << stream.h2_id
      nil
    end

    # Marks `stream` to be answered `status` by the server itself, in its
    # turn (the answer is written by h2_dispatch, never from inside the
    # frame handlers, which may run while another response waits for its
    # window).
    def h2_reject(stream, status)
      return nil if stream.h2_reject_status != 0

      stream.h2_reject_status = status
      stream.h2_deadline = 0.0
      h2_release_body(stream)
      @ready << stream.h2_id
      nil
    end

    # Answers the request of stream `id`, if it is still there.
    def h2_dispatch(id)
      stream = @streams[id]
      return nil if stream.nil? || stream.h2_reset

      status = stream.h2_reject_status
      if status != 0
        refusal = @server.h2_error_response(status)
        h2_respond(stream, h2_fields_of(refusal, false), refusal.body)
        return nil
      end
      body = stream.h2_body
      h2_release_body(stream)
      stream.h2_body = +""
      request = Request.new(stream.h2_method, stream.h2_path, stream.h2_headers, body, @remote_addr, "HTTP/2")
      @conn.awaiting_first_request = false
      response = @server.h2_handle(request)
      if response.upgrade?
        @logger.error("response not written: an upgrade (101) cannot be answered over HTTP/2")
        response = @server.h2_error_response(500)
      end
      writer = response.body_writer
      # A HEAD answer to a stream has the stream's head (no content-length).
      fields = h2_fields_of(response, !writer.nil?)
      if @fields_refused
        # the 500 that replaced it: its own body, and no writer runs
        response = @server.h2_error_response(500)
        writer = nil
      end
      # HEAD, 204 and 304 end with their HEADERS, whatever body or writer
      # the handler set.
      bodyless = request.head? || response.h2_bodyless?
      if writer.nil? || bodyless
        h2_respond(stream, fields, bodyless ? "" : response.body)
      else
        h2_respond_streaming(stream, fields, response, writer)
      end
      nil
    end

    # A whole response: HEADERS, then `body` in DATA frames.
    def h2_respond(stream, fields, body)
      return nil unless h2_send_headers(stream, fields, body.empty?)

      h2_send_data(stream, body, true) unless body.empty?
      h2_finish(stream)
      nil
    end

    # A streaming response: HEADERS, then the writer on this thread with an
    # Http2Sink, then END_STREAM (Http2Sink#sink_finish, from the Server's
    # run_writer_scoped when the writer did not fail).
    def h2_respond_streaming(stream, fields, response, writer)
      return nil unless h2_send_headers(stream, fields, false)

      sink = Http2Sink.new(self, stream.h2_id, @sock, @limits.h2_write_timeout)
      @conn.streaming = true
      ok = @server.h2_run_writer(writer, sink, response.body_log_context)
      @conn.streaming = false
      sink.sink_finish if ok
      raise Http2Closed, "the connection was lost while streaming" if @goaway_sent && !@streams.key?(stream.h2_id)

      h2_send_rst(stream.h2_id, INTERNAL_ERROR) unless ok || stream.h2_reset
      h2_finish(stream)
      nil
    end

    # The response's header list, or a 500's when Response#h2_fields refuses
    # it (CR, LF or NUL stored past set_header); @fields_refused tells the
    # caller, which then answers the 500's body. A plain method for the
    # rescue (NOTES.md rule 11).
    def h2_fields_of(response, streaming)
      @fields_refused = false
      response.h2_fields(streaming)
    rescue ArgumentError => e
      @logger.error("response not written: #{e.message}")
      @fields_refused = true
      @server.h2_error_response(500).h2_fields(false)
    end

    # The stream's response is sent: it is forgotten, and reset with
    # NO_ERROR when the client is still sending its request (section 8.1).
    def h2_finish(stream)
      return nil if stream.h2_reset

      h2_send_rst(stream.h2_id, NO_ERROR) if stream.h2_state == Http2Stream::OPEN
      h2_forget(stream)
      nil
    end

    # A stream whose request waited its turn leaves the queue too, so a
    # client that completes and resets streams while a response is being
    # written does not grow it.
    def h2_forget(stream)
      h2_release_body(stream)
      @streams.delete(stream.h2_id)
      @ready.delete(stream.h2_id)
      nil
    end

    # A stream error: RST_STREAM, and the stream is forgotten.
    def h2_reset(id, code)
      stream = @streams[id]
      h2_send_rst(id, code)
      return nil if stream.nil?

      stream.h2_reset = true
      h2_forget(stream)
      nil
    end

    # The body held for `stream` no longer counts against the connection's
    # budget; the window held back is given back once there is room.
    def h2_release_body(stream)
      held = stream.h2_body.bytesize
      return nil if held == 0

      stream.h2_body = +""
      @buffered -= held
      if @owed > 0 && @buffered <= @limits.h2_max_body_bytes
        owed = @owed
        @owed = 0
        h2_credit_connection(owed)
      end
      nil
    end

    # Reopens the connection's receive window by `n` bytes.
    def h2_credit_connection(n)
      return nil if n <= 0

      @recv_window += n
      h2_send_window_update(0, n)
    end

    # --- writing ----------------------------------------------------------

    def h2_send_settings
      payload = +""
      payload << Http2Session.setting(SETTINGS_MAX_CONCURRENT_STREAMS, @limits.h2_max_streams)
      payload << Http2Session.setting(SETTINGS_MAX_HEADER_LIST_SIZE, @limits.h2_max_head_bytes)
      payload << Http2Session.setting(SETTINGS_ENABLE_PUSH, 0)
      h2_write(Http2Session.frame(SETTINGS, 0, 0, payload))
    end

    # HEADERS (and CONTINUATION past the client's frame size); false when the
    # stream was reset meanwhile.
    def h2_send_headers(stream, fields, end_stream)
      return false if stream.h2_reset

      block = @encoder.hpack_encode(fields)
      out = +""
      max = @peer_max_frame
      flags = end_stream ? FLAG_END_STREAM : 0
      if block.bytesize <= max
        out << Http2Session.frame(HEADERS, flags | FLAG_END_HEADERS, stream.h2_id, block)
      else
        out << Http2Session.frame(HEADERS, flags, stream.h2_id, block.byteslice(0, max))
        off = max
        while off < block.bytesize
          n = block.bytesize - off
          n = max if n > max
          last = off + n >= block.bytesize
          out << Http2Session.frame(CONTINUATION, last ? FLAG_END_HEADERS : 0, stream.h2_id, block.byteslice(off, n))
          off += n
        end
      end
      h2_write(out)
      true
    end

    # `data` as DATA frames within the windows, waiting for WINDOW_UPDATE
    # while they are shut (reading and acting on the frames that come
    # meanwhile); END_STREAM on the last when `end_stream`. False when the
    # stream was reset meanwhile.
    def h2_send_data(stream, data, end_stream)
      n = data.bytesize
      if n == 0
        return false if stream.h2_reset

        h2_write(Http2Session.frame(DATA, end_stream ? FLAG_END_STREAM : 0, stream.h2_id, ""))
        return true
      end
      off = 0
      while off < n
        return false if stream.h2_reset

        room = h2_room(stream)
        if room <= 0
          h2_wait_window(stream)
          next
        end
        take = n - off
        take = room if take > room
        last = off + take >= n
        piece = take == n ? data : data.byteslice(off, take)
        h2_write(Http2Session.frame(DATA, last && end_stream ? FLAG_END_STREAM : 0, stream.h2_id, piece))
        stream.h2_send_window -= take
        @send_window -= take
        off += take
      end
      true
    end

    # How many bytes the next DATA frame on `stream` may carry.
    def h2_room(stream)
      room = @peer_max_frame
      room = stream.h2_send_window if stream.h2_send_window < room
      room = @send_window if @send_window < room
      room
    end

    # Reads and acts on frames until `stream` may send again or was reset;
    # a client that opens no window within stream_write_timeout loses the
    # connection.
    def h2_wait_window(stream)
      deadline = h2_now + @limits.h2_write_timeout.to_f
      while h2_room(stream) <= 0 && !stream.h2_reset
        h2_process_buffered
        break if h2_room(stream) > 0 || stream.h2_reset

        left = deadline - h2_now
        raise Http2Closed, "no WINDOW_UPDATE within stream_write_timeout" if left <= 0.0

        h2_fill(h2_bounded(left))
      end
      nil
    end

    def h2_send_rst(id, code)
      h2_write(Http2Session.frame(RST_STREAM, 0, id, Http2Session.u32_bytes(code)))
    end

    def h2_send_window_update(id, n)
      h2_write(Http2Session.frame(WINDOW_UPDATE, 0, id, Http2Session.u32_bytes(n)))
    end

    def h2_goaway(code, message)
      payload = +""
      payload << Http2Session.u32_bytes(@last_stream_id)
      payload << Http2Session.u32_bytes(code)
      payload << message
      @goaway_sent = true
      h2_write(Http2Session.frame(GOAWAY, 0, 0, payload))
    end

    # GOAWAY for a connection error, where a failing write changes nothing:
    # the connection ends either way. A connection error also ends the
    # streams.
    def h2_goaway_quietly(code, message)
      @logger.info("http2 connection error #{code}: #{message}") if code != NO_ERROR
      begin
        h2_goaway(code, message) unless @goaway_sent && code == NO_ERROR
      rescue Http2Closed, IOError, SystemCallError
        # the peer is gone
      end
      @goaway_sent = true
      @streams.clear
      @ready.clear
      nil
    end

    # write_nonblock and wait_writable, so a client that stops reading
    # cannot hold the connection's thread in a write: past
    # stream_write_timeout without progress the connection ends.
    def h2_write(bytes)
      sock = @sock
      n = bytes.bytesize
      off = 0
      while off < n
        piece = off == 0 ? bytes : bytes.byteslice(off, n - off)
        wrote = sock.write_nonblock(piece, exception: false)
        case wrote
        when Integer
          off += wrote.to_i
        else
          raise Http2Closed, "the connection is closed" if wrote.nil?
          raise Http2Closed, "write past stream_write_timeout" if sock.wait_writable(@limits.h2_write_timeout).nil?
        end
      end
      nil
    end

    # Strips a DATA frame's padding; a PROTOCOL_ERROR when it does not fit.
    def h2_unpad(payload, flags)
      return payload if (flags & FLAG_PADDED) == 0

      raise Http2Error.new(PROTOCOL_ERROR, "DATA too short for its padding") if payload.bytesize < 1

      pad = payload.getbyte(0)
      raise Http2Error.new(PROTOCOL_ERROR, "DATA padding past the frame") if 1 + pad > payload.bytesize

      payload.byteslice(1, payload.bytesize - 1 - pad)
    end

    public

    # --- bytes --------------------------------------------------------------

    # One frame: the 9-byte header and the payload.
    def self.frame(type, flags, stream_id, payload)
      len = payload.bytesize
      out = +""
      out << ((len >> 16) & 255).chr
      out << ((len >> 8) & 255).chr
      out << (len & 255).chr
      out << type.chr
      out << flags.chr
      out << Http2Session.u32_bytes(stream_id & MAX_WINDOW)
      out << payload
      out
    end

    def self.u32_bytes(value)
      out = +""
      out << ((value >> 24) & 255).chr
      out << ((value >> 16) & 255).chr
      out << ((value >> 8) & 255).chr
      out << (value & 255).chr
      out
    end

    def self.setting(key, value)
      out = +""
      out << ((key >> 8) & 255).chr
      out << (key & 255).chr
      out << Http2Session.u32_bytes(value)
      out
    end

    def self.u32(text, pos)
      s = text.to_s # NOTES.md rule 3
      (s.getbyte(pos) << 24) | (s.getbyte(pos + 1) << 16) | (s.getbyte(pos + 2) << 8) | s.getbyte(pos + 3)
    end

    # A 31-bit stream identifier or increment (the reserved bit dropped).
    def self.u31(text, pos)
      Http2Session.u32(text, pos) & MAX_WINDOW
    end

    # A field name as HTTP/2 allows it: a pseudo-header name, or a token
    # without upper case letters (section 8.2.1).
    def self.field_name?(text)
      s = text.to_s # NOTES.md rule 3
      n = s.bytesize
      return false if n == 0

      i = s.getbyte(0) == 58 ? 1 : 0
      return false if i == n

      while i < n
        b = s.getbyte(i)
        return false if (b >= 65 && b <= 90) || !HttpParser.tchar?(b)

        i += 1
      end
      true
    end

    # A field value without CR, LF or NUL, and without whitespace at
    # either end (section 8.2.1).
    def self.field_value?(text)
      s = text.to_s # NOTES.md rule 3
      return false if HttpParser.control_byte_index(s) >= 0

      n = s.bytesize
      return true if n == 0

      first = s.getbyte(0)
      last = s.getbyte(n - 1)
      first != 32 && first != 9 && last != 32 && last != 9
    end

    # Trailers carry no pseudo-header (section 8.1).
    def self.trailers_valid?(fields)
      i = 0
      while i < fields.size
        name = fields[i]
        return false if name.start_with?(":") || !Http2Session.field_name?(name) || !Http2Session.field_value?(fields[i + 1])
        return false if CONNECTION_FIELDS.include?(name) || name == "te"

        i += 2
      end
      true
    end

    # content-length as an Integer, -1 when it is not a plain decimal; more
    # than 18 digits is just over `max` (NOTES.md rule 10).
    def self.content_length_of(value, max)
      s = value.to_s # NOTES.md rule 3
      return -1 unless HttpParser.digits?(s)

      first = 0
      first += 1 while first < s.bytesize - 1 && s.getbyte(first) == 48
      digits = s.bytesize - first
      return max + 1 if digits > 18

      s.byteslice(first, digits).to_i
    end
  end
end
