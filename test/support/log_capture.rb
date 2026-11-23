require "stringio"
require "spinel-http/log"

# The log sink the server tests read, and the assertion that reads it. Not a
# test program itself: `spin test` runs test/*.rb only.
#
# TestLog is an HttpLog that writes each line as `"<LEVEL> <message>\n"`
# (`INFO`, `WARN`, `ERROR`) into an IO, a StringIO in the tests, and drops
# debug lines as the base does.
class TestLog < SpinelHttp::HttpLog
  def initialize(io)
    @io = io
  end

  def info(msg) = write_level("INFO", msg)
  def warn(msg) = write_level("WARN", msg)
  def error(msg) = write_level("ERROR", msg)

  def write_level(level, msg)
    @io.write("#{level} #{msg}\n")
    nil
  end
end

module LogCapture
  # How many lines of `text` are at `level` with a message starting with
  # `message`; a `message` ending in "\n" must be the whole message.
  def self.count(text, level, message)
    whole = message.end_with?("\n")
    wanted = whole ? "#{level} #{message.chomp}" : "#{level} #{message}"
    n = 0
    text.to_s.split("\n").each do |line|
      n += 1 if whole ? line == wanted : line.start_with?(wanted)
    end
    n
  end
end

# Passes when `log` has a line at `level` (`"INFO"`, `"WARN"`, ...) whose
# message starts with `message` (is `message`, when it ends in "\n").
def assert_logged(log, level, message)
  assert LogCapture.count(log, level, message) > 0, "expected a #{level} line starting #{message.inspect} in:\n#{log}"
end
