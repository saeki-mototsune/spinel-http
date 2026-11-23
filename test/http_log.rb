# The HTTP layer's log sink, log context and context switch
# (spinel-http/log.rb). Each case runs where it is written, so the switch
# installed between them is in place for the cases that follow.
require "stringio"
require "spinel-http/log"
require_relative "support/check"

# A context carrying an id, as a framework's subclass would.
class IdContext < SpinelHttp::HttpLogContext
  attr_reader :context_id

  def initialize(id)
    @context_id = id
  end
end

# A switch that keeps the context per thread, as a framework's would.
class ThreadSwitch < SpinelHttp::HttpLogSwitch
  KEY = :http_log_test_context

  def current_context
    value = Thread.current[KEY]
    value.nil? ? SpinelHttp::HttpLogContext::NONE : value
  end

  def swap_context(ctx)
    previous = current_context
    Thread.current[KEY] = ctx.equal?(SpinelHttp::HttpLogContext::NONE) ? nil : ctx
    previous
  end
end

base = SpinelHttp::HttpLogSwitch.installed_switch

test "the installed switch is the base, and its current context is NONE" do
  assert(base.current_context.equal?(SpinelHttp::HttpLogContext::NONE))
end

test "the base switch's swap stores nothing and answers NONE" do
  assert(base.swap_context(IdContext.new("req-0")).equal?(SpinelHttp::HttpLogContext::NONE) &&
           base.current_context.equal?(SpinelHttp::HttpLogContext::NONE))
end

SpinelHttp::HttpLogSwitch.installed_switch = ThreadSwitch.new
ctx = IdContext.new("req-1")
first = IdContext.new("req-first")
seen = Array.new(0) { SpinelHttp::HttpLogContext::NONE }
t = Thread.new do
  seen << SpinelHttp::HttpLogSwitch.installed_switch.swap_context(first)
  seen << SpinelHttp::HttpLogSwitch.installed_switch.swap_context(ctx)
  seen << SpinelHttp::HttpLogSwitch.installed_switch.current_context
  seen << SpinelHttp::HttpLogSwitch.installed_switch.swap_context(SpinelHttp::HttpLogContext::NONE)
  seen << SpinelHttp::HttpLogSwitch.installed_switch.current_context
end
t.join

test "an installed subclass switch, from a second thread: swap answers the previous context" do
  assert(seen[0].equal?(SpinelHttp::HttpLogContext::NONE) && seen[1].equal?(first))
end

test "an installed subclass switch, from a second thread: current there is the swapped-in context" do
  assert(seen[2].equal?(ctx) && ctx.context_id == "req-1")
end

test "an installed subclass switch, from a second thread: swapping NONE back empties it" do
  assert(seen[3].equal?(ctx) && seen[4].equal?(SpinelHttp::HttpLogContext::NONE))
end

test "the main thread's context was never touched" do
  assert(SpinelHttp::HttpLogSwitch.installed_switch.current_context.equal?(SpinelHttp::HttpLogContext::NONE))
end

SpinelHttp::HttpLogSwitch.installed_switch = base

saved = $stderr
captured = StringIO.new
$stderr = captured
log = SpinelHttp::HttpLog.new
answered_nil = log.debug("d").nil?
answered_nil = log.info("i").nil? && answered_nil
answered_nil = log.warn("w").nil? && answered_nil
answered_nil = log.error("x").nil? && answered_nil
$stderr = saved

test "HttpLog writes `level: msg` lines on stderr and drops debug" do
  assert(captured.string == "info: i\nwarn: w\nerror: x\n")
end

test "each HttpLog call answers nil" do
  assert(answered_nil)
end

SpinelHttpTest.summary
