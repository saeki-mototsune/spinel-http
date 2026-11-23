# SpinelHttp::Key.string_of. Under Spinel, Symbol#to_s answers a new frozen
# String at every call and a frozen heap String is never freed, so every
# `key.to_s` of a Symbol key on a request path leaked about 110 bytes. The
# layer names a key with Key.string_of, which answers the Symbol's one
# cached name.
#
# The identity tests hold under CRuby and Spinel alike (Symbol#name is the
# same object at every call), and are what rules the leak out: no call
# allocates.
require "spinel-http/key"
require_relative "support/check"

test "Key.string_of names a Symbol with the same frozen String at every call" do
  a = SpinelHttp::Key.string_of(:user_id)
  b = SpinelHttp::Key.string_of(:user_id)
  assert_equal "user_id", a
  assert a.equal?(b)
  assert a.frozen?
end

test "Key.string_of answers a String key itself and to_s of anything else" do
  s = "title"
  assert s.equal?(SpinelHttp::Key.string_of(s))
  assert_equal "7", SpinelHttp::Key.string_of(7)
  assert_equal "", SpinelHttp::Key.string_of(nil)
end

SpinelHttpTest.summary
