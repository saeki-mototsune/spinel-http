module SpinelHttp
  # A failure to decode an HPACK header block (RFC 7541): an index past the
  # tables, a bad integer or string, an invalid Huffman code, a table size
  # update over the limit. The decoder's state is then lost, so the HTTP/2
  # connection ends with COMPRESSION_ERROR.
  class HpackError < StandardError
  end

  # HPACK header compression for HTTP/2 (RFC 7541): the static table, the
  # canonical Huffman code, and the integer and string representations.
  # Everything works on bytes (getbyte, byteslice) and builds Strings with
  # `<<` (NOTES.md rules 7 and 8).
  class Hpack
    # Index 1..61 of the static table (Appendix A); index 0 is unused.
    STATIC_NAMES = [
      "",
      ":authority",
      ":method",
      ":method",
      ":path",
      ":path",
      ":scheme",
      ":scheme",
      ":status",
      ":status",
      ":status",
      ":status",
      ":status",
      ":status",
      ":status",
      "accept-charset",
      "accept-encoding",
      "accept-language",
      "accept-ranges",
      "accept",
      "access-control-allow-origin",
      "age",
      "allow",
      "authorization",
      "cache-control",
      "content-disposition",
      "content-encoding",
      "content-language",
      "content-length",
      "content-location",
      "content-range",
      "content-type",
      "cookie",
      "date",
      "etag",
      "expect",
      "expires",
      "from",
      "host",
      "if-match",
      "if-modified-since",
      "if-none-match",
      "if-range",
      "if-unmodified-since",
      "last-modified",
      "link",
      "location",
      "max-forwards",
      "proxy-authenticate",
      "proxy-authorization",
      "range",
      "referer",
      "refresh",
      "retry-after",
      "server",
      "set-cookie",
      "strict-transport-security",
      "transfer-encoding",
      "user-agent",
      "vary",
      "via",
      "www-authenticate",
    ]
    STATIC_VALUES = [
      "",
      "",
      "GET",
      "POST",
      "/",
      "/index.html",
      "http",
      "https",
      "200",
      "204",
      "206",
      "304",
      "400",
      "404",
      "500",
      "",
      "gzip, deflate",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
    ]

    # The 257 symbols (256 is EOS) ordered by code length, then code.
    HUFFMAN_SYMBOLS = [
      48, 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37,
      45, 46, 47, 51, 52, 53, 54, 55, 56, 57, 61, 65,
      95, 98, 100, 102, 103, 104, 108, 109, 110, 112, 114, 117,
      58, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76,
      77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 89,
      106, 107, 113, 118, 119, 120, 121, 122, 38, 42, 44, 59,
      88, 90, 33, 34, 40, 41, 63, 39, 43, 124, 35, 62,
      0, 36, 64, 91, 93, 126, 94, 125, 60, 96, 123, 92,
      195, 208, 128, 130, 131, 162, 184, 194, 224, 226, 153, 161,
      167, 172, 176, 177, 179, 209, 216, 217, 227, 229, 230, 129,
      132, 133, 134, 136, 146, 154, 156, 160, 163, 164, 169, 170,
      173, 178, 181, 185, 186, 187, 189, 190, 196, 198, 228, 232,
      233, 1, 135, 137, 138, 139, 140, 141, 143, 147, 149, 150,
      151, 152, 155, 157, 158, 165, 166, 168, 174, 175, 180, 182,
      183, 188, 191, 197, 231, 239, 9, 142, 144, 145, 148, 159,
      171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193,
      200, 201, 202, 205, 210, 213, 218, 219, 238, 240, 242, 243,
      255, 203, 204, 211, 212, 214, 221, 222, 223, 241, 244, 245,
      246, 247, 248, 250, 251, 252, 253, 254, 2, 3, 4, 5,
      6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20,
      21, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220,
      249, 10, 13, 22, 256,
    ]
    # By code length 0..30: the first code of that length, how many codes
    # have it, and the position of the first in HUFFMAN_SYMBOLS.
    HUFFMAN_FIRST_CODE = [
      0, 0, 0, 0, 0, 0, 20, 92, 248, 0, 1016, 2042,
      4090, 8184, 16380, 32764, 0, 0, 0, 524272, 1048550, 2097116, 4194258, 8388568,
      16777194, 33554412, 67108832, 134217694, 268435426, 0, 1073741820,
    ]
    HUFFMAN_COUNT = [
      0, 0, 0, 0, 0, 10, 26, 32, 6, 0, 5, 3,
      2, 6, 2, 3, 0, 0, 0, 3, 8, 13, 26, 29,
      12, 4, 15, 19, 29, 0, 4,
    ]
    HUFFMAN_FIRST_INDEX = [
      0, 0, 0, 0, 0, 0, 10, 36, 68, 0, 74, 79,
      82, 84, 90, 92, 0, 0, 0, 95, 98, 106, 119, 145,
      174, 186, 190, 205, 224, 0, 253,
    ]

    # The longest integer an HPACK representation may carry here: a length,
    # an index or a table size. Past it the block is refused, before the
    # arithmetic could overflow.
    MAX_INTEGER = 16_777_215

    # `value` with an N-bit prefix (`prefix_bits`); `first` holds the bits
    # above the prefix in the first byte (the representation's pattern).
    # Returned, not appended through a parameter (NOTES.md rule 8).
    def self.integer_bytes(value, prefix_bits, first)
      out = +""
      max_prefix = (1 << prefix_bits) - 1
      if value < max_prefix
        out << (first | value).chr
        return out
      end
      out << (first | max_prefix).chr
      rest = value - max_prefix
      while rest >= 128
        out << ((rest & 127) | 128).chr
        rest >>= 7
      end
      out << rest.chr
      out
    end

    # Decodes the Huffman-coded bytes `s[from, len]` (Appendix B). The code
    # is canonical, so a code of length L is a symbol when it falls within
    # the run of codes of that length. Padding must be the most significant
    # bits of EOS (all ones) and shorter than a byte; EOS itself is refused
    # (section 5.2).
    def self.huffman_decode(text, from, len)
      s = text.to_s # NOTES.md rule 3
      out = +""
      code = 0
      bits = 0
      i = from
      stop = from + len
      while i < stop
        b = s.getbyte(i)
        i += 1
        mask = 128
        while mask > 0
          code = (code << 1) | ((b & mask) == 0 ? 0 : 1)
          bits += 1
          mask >>= 1
          count = HUFFMAN_COUNT[bits]
          next if count == 0

          offset = code - HUFFMAN_FIRST_CODE[bits]
          if offset >= 0 && offset < count
            sym = HUFFMAN_SYMBOLS[HUFFMAN_FIRST_INDEX[bits] + offset]
            raise HpackError, "EOS in a Huffman string" if sym == 256

            out << sym.chr
            code = 0
            bits = 0
          elsif bits >= 30
            raise HpackError, "invalid Huffman code"
          end
        end
      end
      raise HpackError, "Huffman padding longer than 7 bits" if bits > 7
      raise HpackError, "Huffman padding is not EOS" if code != (1 << bits) - 1

      out
    end

    # A new String with the bytes of `text`.
    def self.copy_of(text)
      out = +""
      out << text
      out
    end

    # `text` as a string literal without Huffman coding.
    def self.string_bytes(text)
      s = text.to_s # NOTES.md rule 3
      out = +""
      out << Hpack.integer_bytes(s.bytesize, 7, 0)
      out << s
      out
    end

    # The entry size RFC 7541 section 4.1 counts against the table: the
    # name's and the value's bytes plus 32.
    def self.entry_size(name, value)
      name.bytesize + value.bytesize + 32
    end

    # The static-table index of an entry named `name` (lowercase), 0 when
    # the table has none.
    def self.static_name_index(name)
      i = 1
      while i < STATIC_NAMES.size
        return i if STATIC_NAMES[i] == name

        i += 1
      end
      0
    end
  end

  # The decoding side of one HTTP/2 connection: the dynamic table the
  # client's encoder fills, bounded by the size this server advertised
  # (SETTINGS_HEADER_TABLE_SIZE, the default 4096).
  #
  # #hpack_decode answers a header list as an Array of alternating names and
  # values (a flat Array of Strings, so its type is fixed: NOTES.md rule 5).
  # A list whose names and values add up to more than `max_list_bytes`
  # (with RFC 9113's 32 per field) is still decoded to the end, because the
  # dynamic table must stay in step with the client's, but nothing more is
  # kept and #hpack_oversized? turns true. The block being decoded and the
  # position in it are ivars, so every reader answers one value (no mixed
  # [String, Integer] pairs).
  class HpackDecoder
    def initialize(limit = 4096)
      @limit = limit
      @max_size = limit
      @size = 0
      # Newest first, as HPACK numbers the entries (index 62 is the newest).
      @names = Array.new(0) { "" }
      @values = Array.new(0) { "" }
      @oversized = false
      @block = ""
      @pos = 0
    end

    # Whether the last block decoded was over its list limit.
    def hpack_oversized?
      @oversized
    end

    # Entries in the dynamic table (for the tests).
    def hpack_table_count
      @names.size
    end

    # The dynamic table's size as RFC 7541 counts it (for the tests).
    def hpack_table_size
      @size
    end

    def hpack_decode(block, max_list_bytes)
      @block = block.to_s # NOTES.md rule 3
      @pos = 0
      fields = Array.new(0) { "" }
      @oversized = false
      list_bytes = 0
      n = @block.bytesize
      seen_field = false
      while @pos < n
        b = @block.getbyte(@pos)
        name = ""
        value = ""
        if b >= 128
          # 1xxxxxxx: indexed field
          index = hpack_integer(7)
          raise HpackError, "index 0" if index == 0

          name = hpack_name(index)
          value = hpack_value(index)
        elsif b >= 64
          # 01xxxxxx: literal with incremental indexing
          name = hpack_literal_name(hpack_integer(6))
          value = hpack_string
          hpack_insert(name, value)
        elsif b >= 32
          # 001xxxxx: dynamic table size update, only before the first field
          raise HpackError, "table size update after a field" if seen_field

          size = hpack_integer(5)
          raise HpackError, "table size update over the limit" if size > @limit

          @max_size = size
          hpack_evict(0)
          next
        else
          # 0001xxxx never indexed, 0000xxxx without indexing
          name = hpack_literal_name(hpack_integer(4))
          value = hpack_string
        end
        seen_field = true
        list_bytes += Hpack.entry_size(name, value)
        if list_bytes > max_list_bytes
          @oversized = true
        else
          # copies: a caller that edits a field must not edit the tables
          fields << Hpack.copy_of(name)
          fields << Hpack.copy_of(value)
        end
      end
      @block = ""
      fields
    end

    # Changes the table's limit (this server's own setting) to `limit`.
    def hpack_limit=(limit)
      @limit = limit
      @max_size = limit if @max_size > limit
      hpack_evict(0)
    end

    private

    # The integer at @pos with an N-bit prefix; @pos moves past it. Raises
    # HpackError for a truncated integer or one over Hpack::MAX_INTEGER.
    def hpack_integer(prefix_bits)
      s = @block
      n = s.bytesize
      raise HpackError, "truncated integer" if @pos >= n

      max_prefix = (1 << prefix_bits) - 1
      value = s.getbyte(@pos) & max_prefix
      @pos += 1
      return value if value < max_prefix

      shift = 0
      while true
        raise HpackError, "truncated integer" if @pos >= n

        # MAX_INTEGER fits in 24 bits: a fifth continuation byte (a shift
        # past 28) can only be over it, or a run of zero bytes that would
        # push the shift past the word.
        raise HpackError, "integer too long" if shift > 28

        b = s.getbyte(@pos)
        @pos += 1
        value += (b & 127) << shift
        raise HpackError, "integer too large" if value > Hpack::MAX_INTEGER

        break if (b & 128) == 0

        shift += 7
      end
      value
    end

    def hpack_name(index)
      return Hpack::STATIC_NAMES[index] if index < Hpack::STATIC_NAMES.size

      d = index - Hpack::STATIC_NAMES.size
      raise HpackError, "index #{index} past the tables" if d >= @names.size

      @names[d]
    end

    def hpack_value(index)
      return Hpack::STATIC_VALUES[index] if index < Hpack::STATIC_VALUES.size

      @values[index - Hpack::STATIC_VALUES.size]
    end

    # The name of a literal: the table entry `index` names, or a string
    # literal when it is 0.
    def hpack_literal_name(index)
      return hpack_string if index == 0

      hpack_name(index)
    end

    # The string literal at @pos (H bit, 7-bit length, the bytes); @pos
    # moves past it.
    def hpack_string
      s = @block
      raise HpackError, "truncated string" if @pos >= s.bytesize

      huffman = (s.getbyte(@pos) & 128) != 0
      len = hpack_integer(7)
      raise HpackError, "truncated string" if @pos + len > s.bytesize

      from = @pos
      @pos += len
      huffman ? Hpack.huffman_decode(s, from, len) : s.byteslice(from, len)
    end

    def hpack_insert(name, value)
      size = Hpack.entry_size(name, value)
      # An entry larger than the table empties it and is not added
      # (section 4.4).
      hpack_evict(size)
      return nil if size > @max_size

      @names.unshift(name)
      @values.unshift(value)
      @size += size
      nil
    end

    # Drops the oldest entries until `room` more bytes fit.
    def hpack_evict(room)
      while @size + room > @max_size && !@names.empty?
        @size -= Hpack.entry_size(@names[@names.size - 1], @values[@values.size - 1])
        @names.pop
        @values.pop
      end
      nil
    end
  end

  # The encoding side: every field a literal without indexing (the
  # server's dynamic table stays empty, so nothing it sends depends on
  # state the client could lose track of), the name taken from the static
  # table where it is there, and the common :status values indexed. Strings
  # are sent without Huffman coding.
  class HpackEncoder
    def initialize
      # A table size update (to 0) opens the next block: always the first
      # block, and again after the client changes SETTINGS_HEADER_TABLE_SIZE.
      @signal_size = true
    end

    # The client sent SETTINGS_HEADER_TABLE_SIZE.
    def hpack_table_size_changed
      @signal_size = true
      nil
    end

    # `fields`: alternating lowercase names and values.
    def hpack_encode(fields)
      out = +""
      if @signal_size
        out << 32.chr
        @signal_size = false
      end
      i = 0
      while i < fields.size
        name = fields[i]
        value = fields[i + 1]
        i += 2
        index = name == ":status" ? HpackEncoder.status_index(value) : 0
        if index > 0
          out << Hpack.integer_bytes(index, 7, 128)
          next
        end
        index = Hpack.static_name_index(name)
        out << Hpack.integer_bytes(index, 4, 0)
        out << Hpack.string_bytes(name) if index == 0
        out << Hpack.string_bytes(value)
      end
      out
    end

    # The static-table index of `:status: value`, 0 when it has none.
    def self.status_index(value)
      i = 8
      while i <= 14
        return i if Hpack::STATIC_VALUES[i] == value

        i += 1
      end
      0
    end
  end
end
