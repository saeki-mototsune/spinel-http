# SpinelHttpTest: the assertion helper every spinel-http test uses.
#
# A test file requires this one, registers cases with
# `SpinelHttpTest.test "name" do ... end` and ends with
# `SpinelHttpTest.summary`. `spin test` compares the program's stdout with
# test/<name>.rb.expected, so every line is deterministic:
#
#   ok   <name>              a case that raised nothing
#   FAIL <name>: <message>   a case whose assertion failed
#   ERR  <name>: <Class>: <message>   a case that raised something else
#   <n> tests, <m> assertions, <f> failures
#
# A case runs when `test` is called. `summary` prints the totals and exits
# non-zero when anything failed.
#
# Written for both Spinel compilers (NOTES.md): an assertion answers nil, and
# a call that answers nil is never passed as an argument (rule 126), so
# `dropped = res.drop_header("X")`, then `assert_nil dropped`.
class SpinelHttpAssertionFailed < StandardError
end

module SpinelHttpTest
  @tests = 0
  @assertions = 0
  @failures = 0

  def self.count
    @assertions += 1
    nil
  end

  def self.fail_with(text)
    raise SpinelHttpAssertionFailed, text
  end

  def self.test(name)
    @tests += 1
    status = "ok"
    message = ""
    begin
      yield
    rescue SpinelHttpAssertionFailed => e
      status = "FAIL"
      message = e.message
    rescue StandardError => e
      status = "ERR"
      message = "#{e.class.name}: #{e.message}"
    end
    if status == "ok"
      puts "ok   #{name}"
    else
      @failures += 1
      puts "#{status.ljust(4)} #{name}: #{message}"
    end
    nil
  end

  def self.summary
    puts "#{@tests} tests, #{@assertions} assertions, #{@failures} failures"
    exit(1) if @failures > 0
    nil
  end

  def self.check_equal(expected, actual)
    count
    return nil if expected == actual

    text = "Expected: #{expected.inspect}\n  Actual: #{actual.inspect}"
    fail_with(text)
    nil
  end

  def self.check_nil(value)
    count
    return nil if value.nil?

    text = "Expected #{value.inspect} to be nil"
    fail_with(text)
    nil
  end

  def self.check_includes(collection, item)
    count
    return nil if collection.include?(item)

    text = "Expected #{collection.inspect} to include #{item.inspect}"
    fail_with(text)
    nil
  end

  def self.check_raised(klass_name, raised, got)
    count
    return nil if raised && got == klass_name

    text = raised ? "#{klass_name} expected, not #{got}" : "#{klass_name} expected but nothing was raised."
    fail_with(text)
    nil
  end
end

def test(name, &block)
  SpinelHttpTest.test(name, &block)
end

def assert(condition, message = "")
  SpinelHttpTest.count
  return nil if condition

  text = message.empty? ? "Expected condition to be truthy" : message
  SpinelHttpTest.fail_with(text)
  nil
end

def assert_equal(expected, actual)
  SpinelHttpTest.check_equal(expected, actual)
end

def assert_nil(value)
  SpinelHttpTest.check_nil(value)
end

def assert_includes(collection, item)
  SpinelHttpTest.check_includes(collection, item)
end

# Passes when the block raises exactly `klass` (compared by name; a
# subclass does not count). Answers the exception's message.
def assert_raises(klass)
  raised = false
  got = ""
  message = ""
  begin
    yield
  rescue StandardError => e
    raised = true
    got = e.class.name
    message = e.message
  end
  SpinelHttpTest.check_raised(klass.name, raised, got)
  message
end
