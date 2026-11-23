require_relative "support/check"

test "assert passes on a truthy value" do
  assert(1 + 1 == 2, "arithmetic")
end

test "assert_equal passes on equal values" do
  assert_equal("a", "a")
end

test "assert_nil passes on nil" do
  value = nil
  assert_nil value
end

test "assert_includes passes on a member" do
  assert_includes([1, 2, 3], 2)
end

test "assert_raises passes when the block raises" do
  assert_raises(ArgumentError) { raise ArgumentError, "bad" }
end

SpinelHttpTest.summary
