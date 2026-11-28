# SpinelHttp's HPACK (RFC 7541): the examples of Appendix C decoded with
# their dynamic tables, Huffman strings and their padding, integers, table
# size updates and eviction, the list limit, and what the encoder writes.
require "spinel-http/hpack"
require_relative "support/check"

# The bytes a hex string spells.
def unhex(hex)
  out = +""
  i = 0
  while i < hex.bytesize
    out << hex.byteslice(i, 2).to_i(16).chr
    i += 2
  end
  out
end

# A decoded list as "name: value" lines, for comparing.
def lines_of(fields)
  out = Array.new(0) { "" }
  i = 0
  while i < fields.size
    out << "#{fields[i]}: #{fields[i + 1]}"
    i += 2
  end
  out
end

test "C.3 requests without Huffman share one dynamic table" do
  d = SpinelHttp::HpackDecoder.new(4096)
  first = d.hpack_decode(unhex("828684410f7777772e6578616d706c652e636f6d"), 65_536)
  assert_equal [":method: GET", ":scheme: http", ":path: /", ":authority: www.example.com"], lines_of(first)
  assert_equal 57, d.hpack_table_size
  second = d.hpack_decode(unhex("828684be58086e6f2d6361636865"), 65_536)
  assert_equal "cache-control: no-cache", lines_of(second)[4]
  assert_equal ":authority: www.example.com", lines_of(second)[3]
  assert_equal 110, d.hpack_table_size
  third = d.hpack_decode(unhex("828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), 65_536)
  assert_equal [":method: GET", ":scheme: https", ":path: /index.html", ":authority: www.example.com", "custom-key: custom-value"], lines_of(third)
  assert_equal 3, d.hpack_table_count
  assert_equal 164, d.hpack_table_size
end

test "C.4 requests with Huffman" do
  d = SpinelHttp::HpackDecoder.new(4096)
  first = d.hpack_decode(unhex("828684418cf1e3c2e5f23a6ba0ab90f4ff"), 65_536)
  assert_equal ":authority: www.example.com", lines_of(first)[3]
  second = d.hpack_decode(unhex("828684be5886a8eb10649cbf"), 65_536)
  assert_equal "cache-control: no-cache", lines_of(second)[4]
  third = d.hpack_decode(unhex("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf"), 65_536)
  assert_equal "custom-key: custom-value", lines_of(third)[4]
  assert_equal 164, d.hpack_table_size
end

test "C.6 responses with Huffman evict from a 256-byte table" do
  d = SpinelHttp::HpackDecoder.new(256)
  first = d.hpack_decode(unhex("488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"), 65_536)
  assert_equal [":status: 302", "cache-control: private", "date: Mon, 21 Oct 2013 20:13:21 GMT", "location: https://www.example.com"], lines_of(first)
  assert_equal 222, d.hpack_table_size
  second = d.hpack_decode(unhex("4883640effc1c0bf"), 65_536)
  assert_equal [":status: 307", "cache-control: private", "date: Mon, 21 Oct 2013 20:13:21 GMT", "location: https://www.example.com"], lines_of(second)
  assert_equal 222, d.hpack_table_size
  third = d.hpack_decode(unhex("88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007"), 65_536)
  assert_equal ["content-encoding: gzip", "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"], lines_of(third)[4, 2]
  assert_equal 215, d.hpack_table_size
  assert_equal 3, d.hpack_table_count
end

test "Huffman decodes every byte value" do
  # "\x00\xff" (13 + 26 bits), padded with ones: two symbols of the long codes
  nul = SpinelHttp::Hpack.huffman_decode(unhex("ffc7"), 0, 2)
  assert_equal 1, nul.bytesize
  assert_equal 0, nul.getbyte(0)
  decoded = SpinelHttp::Hpack.huffman_decode(unhex("f1e3c2e5f23a6ba0ab90f4ff"), 0, 12)
  assert_equal "www.example.com", decoded
end

test "Huffman refuses EOS, padding over 7 bits and padding that is not ones" do
  assert_raises(SpinelHttp::HpackError) { SpinelHttp::Hpack.huffman_decode(unhex("fffffffc"), 0, 4) }
  assert_raises(SpinelHttp::HpackError) { SpinelHttp::Hpack.huffman_decode(unhex("1fff"), 0, 2) }
  # "0" is 00000; padded with zeros instead of ones
  assert_raises(SpinelHttp::HpackError) { SpinelHttp::Hpack.huffman_decode(unhex("00"), 0, 1) }
  assert_equal "0", SpinelHttp::Hpack.huffman_decode(unhex("07"), 0, 1)
end

test "an index past the tables, index 0 and a truncated block are errors" do
  d = SpinelHttp::HpackDecoder.new(4096)
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("be"), 65_536) }
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("80"), 65_536) }
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("400a6375"), 65_536) }
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("ff"), 65_536) }
  # an integer past the limit, and one padded with zero continuation bytes
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("ffffffffff0f"), 65_536) }
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("ff808080808080808080808001"), 65_536) }
end

test "a table size update must come first and stay within the limit" do
  d = SpinelHttp::HpackDecoder.new(4096)
  d.hpack_decode(unhex("400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), 65_536)
  assert_equal 1, d.hpack_table_count
  # 0x20: size 0, which empties the table
  fields = d.hpack_decode(unhex("2082"), 65_536)
  assert_equal [":method: GET"], lines_of(fields)
  assert_equal 0, d.hpack_table_count
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("8220"), 65_536) }
  # 4097 is over the advertised 4096: 3f e2 1f
  assert_raises(SpinelHttp::HpackError) { d.hpack_decode(unhex("3fe21f"), 65_536) }
end

test "a list over its limit is decoded to the end but not kept" do
  d = SpinelHttp::HpackDecoder.new(4096)
  fields = d.hpack_decode(unhex("828684400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), 100)
  assert d.hpack_oversized?
  assert_equal 1, d.hpack_table_count
  assert_equal [":method: GET", ":scheme: http"], lines_of(fields)
  small = d.hpack_decode(unhex("82"), 100)
  refute d.hpack_oversized?
  assert_equal 1, lines_of(small).size
end

test "the encoder indexes :status, names from the static table and signals size 0 first" do
  e = SpinelHttp::HpackEncoder.new
  block = e.hpack_encode([":status", "200", "content-type", "text/plain", "x-custom", "v"])
  d = SpinelHttp::HpackDecoder.new(4096)
  assert_equal [":status: 200", "content-type: text/plain", "x-custom: v"], lines_of(d.hpack_decode(block, 65_536))
  assert_equal 32, block.getbyte(0)
  assert_equal 0x88, block.getbyte(1)
  again = e.hpack_encode([":status", "418"])
  assert_equal 0x08, again.getbyte(0)
  assert_equal [":status: 418"], lines_of(d.hpack_decode(again, 65_536))
  e.hpack_table_size_changed
  assert_equal 32, e.hpack_encode([":status", "204"]).getbyte(0)
end

test "integers past one byte, and a long value, round-trip" do
  assert unhex("1f9a0a") == SpinelHttp::Hpack.integer_bytes(1337, 5, 0)
  long = "v" * 300
  e = SpinelHttp::HpackEncoder.new
  d = SpinelHttp::HpackDecoder.new(4096)
  fields = d.hpack_decode(e.hpack_encode(["x-long", long, "set-cookie", "a=1", "set-cookie", "b=2"]), 65_536)
  assert_equal 300, fields[1].bytesize
  assert_equal ["set-cookie: a=1", "set-cookie: b=2"], lines_of(fields)[1, 2]
end

test "a decoded field is a copy: editing it leaves the table as sent" do
  d = SpinelHttp::HpackDecoder.new(4096)
  first = d.hpack_decode(unhex("400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), 65_536)
  first[1] << "-edited"
  again = d.hpack_decode(unhex("be"), 65_536)
  assert_equal "custom-value", again[1]
end

SpinelHttpTest.summary
