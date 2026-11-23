module SpinelHttp
  # The parsed request line and headers of one HTTP/1.x request.
  class RequestHead
    # headers: names lowercased, values stripped, duplicates joined with ", "
    attr_reader :method, :target, :http_version, :headers

    def initialize(method, target, http_version, headers)
      @method = method
      @target = target
      @http_version = http_version
      @headers = headers
    end
  end

  # Parses the head (request line + header lines) of an HTTP/1.x request.
  # The Server scans its socket buffer for HEAD_END (byteindex) and hands
  # everything before it to parse_head. Percent-decoding of the target is
  # left to Query and Request.split_path.
  class HttpParser
    class ParseError < StandardError
    end

    HEAD_END = "\r\n\r\n"
    SUPPORTED_VERSIONS = ["HTTP/1.1", "HTTP/1.0"]

    def self.parse_head(head)
      lines = head.split("\r\n")
      # RFC 9112 section 2.2: ignore empty lines before the request line
      # (e.g. a stray CRLF after a POST body on a keep-alive connection).
      first = 0
      first += 1 while first < lines.size && lines[first].empty?
      raise ParseError, "empty request" if first >= lines.size

      request_line = lines[first]
      raise ParseError, "CR, LF or NUL in the request line" if HttpParser.control_byte_index(request_line) >= 0

      method, target, version = parse_request_line(request_line)
      header_values = {}
      i = first + 1
      while i < lines.size
        line = lines[i]
        i += 1
        next if line.empty?

        # RFC 9110 section 5.5: a field line holding CR, LF or NUL is
        # refused, not repaired. A front end may take a bare LF for a line
        # end (RFC 9112 section 2.2) and see a header that this parser would
        # read as part of a value ("X: a\nTransfer-Encoding: chunked").
        raise ParseError, "CR, LF or NUL in a header line" if HttpParser.control_byte_index(line) >= 0

        colon = line.index(":")
        raise ParseError, "malformed header line: #{line}" if colon.nil? || colon == 0

        # RFC 9110 section 5.1: a field name is a token. That refuses
        # whitespace before the colon or inside the name (RFC 9112 section
        # 5.1, a request-smuggling vector), obs-fold lines, and any other
        # byte a front end might drop or fold ("Content-Length\v").
        name = line[0, colon]
        raise ParseError, "invalid header name: #{line}" unless HttpParser.field_name_token?(name)

        name = name.downcase
        value = line[colon + 1, line.size - colon - 1].strip
        values = header_values[name]
        if values.nil?
          header_values[name] = [value]
        else
          values << value
        end
      end
      # Join once per name: rebuilding a growing String for every duplicate
      # makes many short headers quadratic even within the server's byte cap.
      headers = {}
      header_values.each { |name, values| headers[name] = values.join(", ") }
      RequestHead.new(method, target, version, headers)
    end

    def self.parse_request_line(line)
      parts = line.split(" ")
      raise ParseError, "malformed request line: #{line}" unless parts.size == 3

      version = parts[2]
      unless SUPPORTED_VERSIONS.include?(version)
        raise ParseError, "unsupported HTTP version: #{version}"
      end
      [parts[0], parts[1], version]
    end

    # The byte offset of the first CR, LF or NUL in `text`, -1 when it has
    # none. A byte loop: a String literal holding NUL is not safe to search
    # for under Spinel (NOTES.md rule 8), and the scan allocates nothing.
    def self.control_byte_index(text)
      s = text.to_s # NOTES.md rule 3
      n = s.bytesize
      i = 0
      while i < n
        b = s.getbyte(i)
        return i if b == 13 || b == 10 || b == 0

        i += 1
      end
      -1
    end

    # Whether `text` is an RFC 9110 token (one or more tchar), as a field
    # name must be.
    def self.field_name_token?(text)
      s = text.to_s # NOTES.md rule 3
      n = s.bytesize
      return false if n == 0

      i = 0
      while i < n
        return false unless HttpParser.tchar?(s.getbyte(i))

        i += 1
      end
      true
    end

    # An RFC 9110 tchar: ALPHA, DIGIT or one of !#$%&'*+-.^_`|~.
    def self.tchar?(b)
      return true if (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57)

      b == 33 || (b >= 35 && b <= 39) || b == 42 || b == 43 || b == 45 || b == 46 || b == 94 || b == 95 || b == 96 || b == 124 || b == 126
    end

    # True when text is one or more ASCII digits, false for "" (the
    # Content-Length readers, Request#content_length and Server#body_length,
    # treat an empty value as malformed). A while loop over getbyte: no
    # Array and no block per request, as `bytes.all?` would cost. `value`
    # is a nullable header value, boxed, hence the `to_s` local: a boxed
    # `getbyte` raises NoMethodError in a program that requires the openssl
    # package (NOTES.md rule 3).
    def self.digits?(value)
      text = value.to_s # NOTES.md rule 3
      n = text.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = text.getbyte(i)
        return false if b < 48 || b > 57
        i += 1
      end
      true
    end
  end
end
