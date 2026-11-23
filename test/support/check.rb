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
# Assertions: assert, refute, assert_equal, assert_nil, assert_includes and
# assert_raises, with Minitest's failure texts (assert_raises takes a Class,
# or a String matched against the raised class's name).
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

  BUILTIN_PARENTS = {
    "Exception" => "", "StandardError" => "Exception", "ScriptError" => "Exception",
    "NoMemoryError" => "Exception", "SecurityError" => "Exception", "SignalException" => "Exception",
    "SystemExit" => "Exception", "SystemStackError" => "Exception", "Interrupt" => "SignalException",
    "LoadError" => "ScriptError", "NotImplementedError" => "ScriptError", "SyntaxError" => "ScriptError",
    "ArgumentError" => "StandardError", "EncodingError" => "StandardError", "FiberError" => "StandardError",
    "IOError" => "StandardError", "IndexError" => "StandardError", "LocalJumpError" => "StandardError",
    "NameError" => "StandardError", "RangeError" => "StandardError", "RegexpError" => "StandardError",
    "RuntimeError" => "StandardError", "SystemCallError" => "StandardError", "ThreadError" => "StandardError",
    "TypeError" => "StandardError", "ZeroDivisionError" => "StandardError", "EOFError" => "IOError",
    "KeyError" => "IndexError", "StopIteration" => "IndexError", "ClosedQueueError" => "StopIteration",
    "NoMethodError" => "NameError", "FloatDomainError" => "RangeError", "FrozenError" => "RuntimeError",
    "UncaughtThrowError" => "ArgumentError", "NoMatchingPatternError" => "StandardError",
    "NoMatchingPatternKeyError" => "NoMatchingPatternError", "Math::DomainError" => "StandardError",
    "Timeout::Error" => "RuntimeError", "Timeout::ExitException" => "Exception", "SocketError" => "StandardError",
    "Date::Error" => "ArgumentError", "JSON::JSONError" => "StandardError", "JSON::ParserError" => "JSON::JSONError",
    "JSON::NestingError" => "JSON::ParserError", "JSON::GeneratorError" => "JSON::JSONError",
    "Encoding::CompatibilityError" => "EncodingError", "Encoding::UndefinedConversionError" => "EncodingError",
    "Encoding::InvalidByteSequenceError" => "EncodingError", "Encoding::ConverterNotFoundError" => "EncodingError",
    "URI::Error" => "StandardError", "URI::InvalidURIError" => "URI::Error",
    "URI::InvalidComponentError" => "URI::Error", "URI::BadURIError" => "URI::Error",
    "IO::EAGAINWaitReadable" => "Errno::EAGAIN", "IO::EAGAINWaitWritable" => "Errno::EAGAIN",
    "IO::TimeoutError" => "IOError", "Regexp::TimeoutError" => "RegexpError"
  }.freeze

  # The name assert_raises prints for what it expects: the class's name, the
  # text given, or StandardError when nothing was.
  def self.expected_text(expected)
    case expected
    when String then expected == "" ? "StandardError" : expected
    else expected.name.to_s
    end
  end

  # Whether the raised class is what `expected` names: a Class by name along
  # the superclass chain, a String as part of the name, "" any StandardError
  # (`standard`: the exception is one). A built-in class whose parent is
  # unknown fails the assertion when it is a StandardError, and does not match
  # (so it is raised on) when it is not.
  def self.raised_matches?(expected, raised, standard)
    if expected.is_a?(String)
      return standard if expected == ""

      return raised.name.to_s.include?(expected)
    end
    want = expected.name.to_s
    k = raised
    name = k.name.to_s
    builtin = false
    loop do
      return true if name == want

      parent = builtin_parent(name)
      if parent.nil? && !builtin
        up = superclass_or_nil(k)
        if up.nil?
          return false unless standard

          text = "assert_raises: the parent class of #{name} is not known under Spinel; " \
                 "expect #{name} itself, or compare by name: assert_raises(\"#{want}\")"
          fail_with(text)
        end
        k = up
        name = k.name.to_s
      else
        builtin = true
        return false if parent.nil? || parent == ""

        name = parent
      end
    end
    false
  end

  # The parent of one of Ruby's own exception classes, by name.
  def self.builtin_parent(name)
    parent = BUILTIN_PARENTS[name]
    return parent unless parent.nil?
    return "SystemCallError" if name.start_with?("Errno::")

    nil
  end

  # A user class's superclass; nil where `superclass` raises, as it does
  # under Spinel for a class of Ruby's own in a program that defines a module.
  def self.superclass_or_nil(klass)
    klass.superclass
  rescue StandardError
    nil
  end

  # assert_raises, given what its block raised: a failed assertion the caller
  # did not name is raised on, and so is an unexpected exception that is not a
  # StandardError; another class than expected fails with Minitest's text.
  def self.raise_unless_expected(expected, exception)
    name = exception.class.name.to_s
    if name.include?("AssertionFailed") && !expected_text(expected).include?("AssertionFailed")
      raise exception
    end
    return nil if raised_matches?(expected, exception.class, exception.is_a?(StandardError))
    raise exception unless exception.is_a?(StandardError)

    text = "[#{expected_text(expected)}] exception expected, not\nClass: <#{name}>\nMessage: <#{exception.message.inspect}>"
    fail_with(text)
    nil
  end

  def self.check_raised(expected, raised)
    return nil if raised

    text = "#{expected_text(expected)} expected but nothing was raised."
    fail_with(text)
    nil
  end
end

def test(name, &block)
  SpinelHttpTest.test(name, &block)
end

def flunk(message)
  raise SpinelHttpAssertionFailed, message
end

def assert(condition, message = "expected condition to be truthy")
  SpinelHttpTest.count
  flunk(message) unless condition
end

def refute(condition, message = "expected condition to be falsy")
  SpinelHttpTest.count
  flunk(message) if condition
end

def assert_equal(expected, actual)
  SpinelHttpTest.check_equal(expected, actual)
end

def assert_nil(actual)
  SpinelHttpTest.count
  flunk("expected nil, got #{actual.inspect}") unless actual.nil?
end

# Passes when a String contains `needle.to_s` or an Array includes `needle`.
# Any other haystack fails. The receiver is narrowed first and the String
# case goes through #index (include? on a polymorphic receiver mis-dispatches
# under Spinel).
def assert_includes(haystack, needle)
  SpinelHttpTest.count
  found = false
  case haystack
  when String
    n = needle.to_s
    found = !haystack.index(n).nil?
  when Array
    found = haystack.include?(needle)
  end
  unless found
    flunk("expected #{haystack.inspect} to include #{needle.inspect}")
  end
end

# Passes when the block raises the exception `expected` names, and answers
# that exception's message (a String). A Class matches that class or a
# subclass; a String matches a class whose name contains it; nothing given
# matches any StandardError. A failed assertion inside the block is raised on
# unless `expected` names AssertionFailed. Failures: `[ArgumentError]
# exception expected, not` with the raised class and message on the next two
# lines, or `ArgumentError expected but nothing was raised.`
def assert_raises(expected = "")
  SpinelHttpTest.count
  message = ""
  raised = false
  begin
    yield
  rescue Exception => e
    SpinelHttpTest.raise_unless_expected(expected, e)
    raised = true
    message = e.message
  end
  SpinelHttpTest.check_raised(expected, raised)
  message
end
