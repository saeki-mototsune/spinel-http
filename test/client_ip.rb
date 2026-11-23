# Request#loopback?, #client_ip and #base_url, Request.trusted_proxy and
# Request.trusted_proxies, and IpAddress: which address a rate limit counts
# and which scheme an absolute URL gets behind a reverse proxy. Pure Ruby
# (no server), so this program runs under CRuby too.
require "spinel-http/request"
require_relative "support/check"

Request = SpinelHttp::Request
IpAddress = SpinelHttp::IpAddress

def from(addr, forwarded)
  headers = { "host" => "example.com" }
  headers["x-forwarded-for"] = forwarded unless forwarded.empty?
  Request.new("POST", "/session", headers, "", addr)
end

def proto(addr, scheme)
  headers = { "host" => "example.com" }
  headers["x-forwarded-proto"] = scheme unless scheme.empty?
  Request.new("GET", "/", headers, "", addr)
end

def no_trusted_proxies
  Array.new(0) { "" }
end

test "loopback? is 127.0.0.0/8, ::1 and IPv4-mapped 127.x.x.x" do
  ["127.0.0.1", "127.255.0.9", "127.1.2.3", "::1", "::ffff:127.0.0.1", "::FFFF:127.9.9.9"].each do |addr|
    assert from(addr, "").loopback?, addr
  end
end

test "loopback? is false for every other address" do
  ["", "128.0.0.1", "10.0.0.1", "192.168.1.1", "127.0.0", "127.0.0.256", "127.0.0.1.5", "127..0.1",
   "127.0.0.1x", "1270.0.0.1", "0127.0.0.1", "::2", "::ffff:10.0.0.1", "::fff:127.0.0.1", "localhost",
   "2001:db8::1"].each do |addr|
    refute from(addr, "").loopback?, addr
  end
end

test "without a trusted proxy client_ip is the peer, whatever X-Forwarded-For says" do
  Request.trusted_proxy = false
  assert_equal "127.0.0.1", from("127.0.0.1", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "").client_ip
end

test "with a trusted proxy a loopback peer's last X-Forwarded-For hop is the client" do
  Request.trusted_proxy = true
  assert_equal "203.0.113.9", from("127.0.0.1", "203.0.113.9").client_ip
  # Earlier hops are the client's own words: only the proxy's is used.
  assert_equal "203.0.113.9", from("127.0.0.1", "10.9.9.9, 1.2.3.4,203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::1", " 6.6.6.6 ,\t203.0.113.9 \t").client_ip
  assert_equal "2001:db8::7", from("::ffff:127.0.0.1", "2001:db8::7").client_ip
  # No header: the peer.
  assert_equal "127.0.0.1", from("127.0.0.1", "").client_ip
  Request.trusted_proxy = false
end

test "with a trusted proxy a peer that is not loopback keeps its own address" do
  Request.trusted_proxy = true
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  assert_equal "", from("", "203.0.113.9").client_ip
  Request.trusted_proxy = false
end

test "a last hop that is empty, too long or not printable ASCII falls back to the peer" do
  Request.trusted_proxy = true
  long = "1" * 46
  just_fits = "1" * 45
  bad = ["203.0.113.9,", "203.0.113.9, ", " ", ",", long, "1.2.3.4 5", "1.2.3.4\x7f", "1.2\x013"]
  bad.each do |value|
    assert_equal "127.0.0.1", from("127.0.0.1", value).client_ip
  end
  assert_equal just_fits, from("127.0.0.1", just_fits).client_ip
  # Bytes that are not valid UTF-8 are scanned, never split or stripped.
  invalid = "1.1.1.1, \xFFA".b
  assert_equal "127.0.0.1", from("127.0.0.1", invalid).client_ip
  earlier_invalid = "\xC3(, 203.0.113.9".b
  assert_equal "203.0.113.9", from("127.0.0.1", earlier_invalid).client_ip
  Request.trusted_proxy = false
end

test "Request.trusted_proxy is false until set" do
  assert_equal false, Request.trusted_proxy
  Request.trusted_proxy = true
  assert_equal true, Request.trusted_proxy
  Request.trusted_proxy = false
  assert_equal false, Request.trusted_proxy
end

test "a peer inside a trusted IPv4 CIDR names the client; one outside does not" do
  Request.trusted_proxies = ["172.16.0.0/12", "10.0.0.0/8"]
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("172.31.255.255", "6.6.6.6, 203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("10.200.0.1", "203.0.113.9").client_ip
  # IPv4-mapped peers (a dual-stack listener) match the IPv4 entry.
  assert_equal "203.0.113.9", from("::ffff:172.18.0.2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::FFFF:10.0.0.1", "203.0.113.9").client_ip
  # Just outside, another network, and loopback (trusted_proxy is off).
  ["172.15.255.255", "172.32.0.1", "11.0.0.1", "192.168.1.1", "127.0.0.1", "::ffff:172.32.0.1",
   "::1", "2001:db8::1", "", "not an address"].each do |outside|
    assert_equal outside, from(outside, "203.0.113.9").client_ip
  end
  # No header, or a bad last hop: the peer.
  assert_equal "172.18.0.2", from("172.18.0.2", "").client_ip
  assert_equal "172.18.0.2", from("172.18.0.2", "203.0.113.9,").client_ip
  Request.trusted_proxies = no_trusted_proxies
end

test "a single trusted address matches only itself" do
  Request.trusted_proxies = ["172.18.0.2"]
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "172.18.0.3", from("172.18.0.3", "203.0.113.9").client_ip
  Request.trusted_proxies = ["10.0.0.0/0"]
  assert_equal "203.0.113.9", from("198.51.100.1", "203.0.113.9").client_ip
  Request.trusted_proxies = no_trusted_proxies
end

test "IPv6 trusted networks: compressed, zone ignored on the peer, bounded prefixes" do
  Request.trusted_proxies = ["fd00::/8", "2001:db8:0:1::/64", "fe80::/10"]
  assert_equal "203.0.113.9", from("fd12:3456::1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("2001:db8:0:1:ffff::2", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("fe80::1%eth0", "203.0.113.9").client_ip
  assert_equal "2001:db8:0:2::1", from("2001:db8:0:2::1", "203.0.113.9").client_ip
  assert_equal "fc00::1", from("fc00::1", "203.0.113.9").client_ip
  # An IPv6 network does not take an IPv4 peer that it does not cover.
  assert_equal "172.18.0.2", from("172.18.0.2", "203.0.113.9").client_ip
  Request.trusted_proxies = ["::1"]
  assert_equal "203.0.113.9", from("::1", "203.0.113.9").client_ip
  assert_equal "::2", from("::2", "203.0.113.9").client_ip
  Request.trusted_proxies = no_trusted_proxies
end

test "Request.trusted_proxies is empty until set and refuses a bad entry" do
  assert_equal 0, Request.trusted_proxies.size
  Request.trusted_proxies = ["172.16.0.0/12", "fd00::/8"]
  assert_equal ["172.16.0.0/12", "fd00::/8"], Request.trusted_proxies
  msg = assert_raises("ArgumentError") { Request.trusted_proxies = ["172.16.0.0/33"] }
  assert_includes msg, "172.16.0.0/33"
  # A refused list leaves the installed one as it was.
  assert_equal ["172.16.0.0/12", "fd00::/8"], Request.trusted_proxies
  Request.trusted_proxies = no_trusted_proxies
  assert_equal 0, Request.trusted_proxies.size
end

test "the loopback shorthand and the list add up" do
  Request.trusted_proxy = true
  Request.trusted_proxies = ["172.16.0.0/12"]
  assert_equal "203.0.113.9", from("127.0.0.1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("::1", "203.0.113.9").client_ip
  assert_equal "203.0.113.9", from("172.18.0.2", "203.0.113.9").client_ip
  assert_equal "198.51.100.1", from("198.51.100.1", "203.0.113.9").client_ip
  Request.trusted_proxy = false
  Request.trusted_proxies = no_trusted_proxies
end

test "base_url is http and the Host header unless a trusted proxy says https" do
  Request.trusted_proxy = false
  assert_equal "http://example.com", proto("127.0.0.1", "").base_url
  # An untrusted peer's X-Forwarded-Proto is the client's own word.
  assert_equal "http://example.com", proto("127.0.0.1", "https").base_url
  assert_equal "http://example.com", proto("198.51.100.1", "https").base_url
  Request.trusted_proxy = true
  assert_equal "https://example.com", proto("127.0.0.1", "https").base_url
  assert_equal "http://example.com", proto("127.0.0.1", "http").base_url
  assert_equal "http://example.com", proto("127.0.0.1", "HTTPS").base_url
  assert_equal "http://example.com", proto("127.0.0.1", "").base_url
  assert_equal "http://example.com", proto("198.51.100.1", "https").base_url
  Request.trusted_proxy = false
  Request.trusted_proxies = ["172.16.0.0/12"]
  assert_equal "https://example.com", proto("172.18.0.2", "https").base_url
  assert_equal "http://example.com", proto("10.0.0.1", "https").base_url
  Request.trusted_proxies = no_trusted_proxies
  # No Host header: an empty host.
  assert_equal "http://", Request.new("GET", "/", {}, "", "127.0.0.1").base_url
  assert_equal "http://localhost:3000", Request.new("GET", "/", { "host" => "localhost:3000" }, "", "127.0.0.1").base_url
end

test "IpAddress.parse_network bounds prefixes and refuses what is not a network" do
  ["172.16.0.0/12", "10.0.0.0/8", "172.18.0.2", "0.0.0.0/0", "1.2.3.4/32", "::/0", "::1",
   "fd00::/8", "2001:db8::/128", "::ffff:10.0.0.0/104"].each do |accepted|
    assert_equal 17, IpAddress.parse_network(accepted).size
  end
  ["", "/8", "10.0.0.0/", "10.0.0.0/33", "::/129", "10.0.0.0/8/8", "10.0.0.0/8x", "10.0.0.0/-1",
   "10.0.0.0/0008", "10.0.0", "010.0.0.1", "10.0.0.256", "fe80::1%eth0", "fe80::/10%eth0", "::1::",
   "1:2:3:4:5:6:7:8:9", "gggg::", "localhost", " 10.0.0.1", "10.0.0.1 "].each do |refused|
    assert_equal 0, IpAddress.parse_network(refused).size
  end
  # An IPv4 entry is stored as its IPv4-mapped network: prefix + 96.
  assert_equal 108, IpAddress.parse_network("172.16.0.0/12")[0]
  assert_equal 128, IpAddress.parse_network("fd00::1")[0]
end

test "IpAddress.bytes16 reads IPv4, IPv4-mapped and IPv6 text, and refuses the rest" do
  assert_equal [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 0, 0, 1], IpAddress.bytes16("10.0.0.1")
  assert_equal IpAddress.bytes16("10.0.0.1"), IpAddress.bytes16("::ffff:10.0.0.1")
  assert_equal [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], IpAddress.bytes16("::1")
  assert_equal [254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], IpAddress.bytes16("fe80::1%eth0")
  assert_equal [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], IpAddress.bytes16("2001:DB8::1")
  ["", "10.0.0", "10.0.0.256", "::1::", "1:2:3:4:5:6:7:8:9", "gggg::", "localhost"].each do |refused|
    assert_equal 0, IpAddress.bytes16(refused).size
  end
end

test "IpAddress.in_networks? matches a parsed list, and an empty list matches nothing" do
  networks = IpAddress.parse_network("192.168.0.0/16") + IpAddress.parse_network("fd00::/8")
  assert IpAddress.in_networks?("192.168.4.5", networks)
  assert IpAddress.in_networks?("::ffff:192.168.4.5", networks)
  assert IpAddress.in_networks?("fd00::9", networks)
  refute IpAddress.in_networks?("192.169.0.1", networks)
  refute IpAddress.in_networks?("fe00::1", networks)
  refute IpAddress.in_networks?("not an address", networks)
  refute IpAddress.in_networks?("192.168.4.5", Array.new(0) { 0 })
end

SpinelHttpTest.summary
