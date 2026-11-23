require_relative "support/check"

class CheckError < StandardError
end

class CheckChildError < CheckError
end

# The failure text of a failing assertion: a failed assertion inside the
# block is the one assert_raises("AssertionFailed") is for.
def failure_text
  assert_raises("AssertionFailed") { yield }
end

test "assert passes on a truthy value" do
  assert(1 + 1 == 2, "arithmetic")
end

test "assert fails with its message, or the default" do
  assert_equal("custom", failure_text { assert(false, "custom") })
  assert_equal("expected condition to be truthy", failure_text { assert(nil) })
end

test "refute passes on false and nil" do
  refute false
  refute nil, "never shown"
end

test "refute fails with its message, or the default" do
  assert_equal("custom", failure_text { refute(true, "custom") })
  assert_equal("expected condition to be falsy", failure_text { refute(1) })
end

test "assert_equal passes on equal values and fails with two lines" do
  assert_equal("a", "a")
  assert_equal("Expected: 1\n  Actual: \"x\"", failure_text { assert_equal(1, "x") })
end

test "assert_nil passes on nil and fails with the value" do
  assert_nil nil
  assert_equal("expected nil, got \"x\"", failure_text { assert_nil "x" })
end

test "assert_includes covers a String and an Array" do
  assert_includes([1, 2, 3], 2)
  assert_includes("hello world", "o w")
  assert_equal("expected [1] to include 2", failure_text { assert_includes([1], 2) })
  assert_equal("expected \"abc\" to include \"z\"", failure_text { assert_includes("abc", "z") })
end

test "assert_raises matches a class, a subclass and a name" do
  assert_raises(ArgumentError) { raise ArgumentError, "bad" }
  assert_raises(CheckError) { raise CheckChildError, "child" }
  assert_raises("CheckChild") { raise CheckChildError, "child" }
  assert_raises { raise CheckError, "any standard error" }
  assert_raises(StandardError) { raise ArgumentError, "builtin parent" }
end

test "assert_raises answers the message" do
  message = assert_raises(CheckError) { raise CheckError, "the message" }
  assert_equal("the message", message)
end

test "assert_raises fails with Minitest's texts" do
  assert_equal("ArgumentError expected but nothing was raised.", failure_text { assert_raises(ArgumentError) { 1 } })
  assert_equal("CheckError expected but nothing was raised.", failure_text { assert_raises("CheckError") { 1 } })
  assert_equal("[ArgumentError] exception expected, not\nClass: <CheckError>\nMessage: <\"other\">",
               failure_text { assert_raises(ArgumentError) { raise CheckError, "other" } })
end

test "assert_raises raises on a failed assertion inside the block" do
  assert_equal("Expected: 1\n  Actual: 2", failure_text { assert_raises(CheckError) { assert_equal(1, 2) } })
end

SpinelHttpTest.summary
