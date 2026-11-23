module SpinelHttp
  # What the Server tells when a streamed or upgraded body's writer raised:
  # {Server} calls {#stream_failed} on {SpinelHttp.stream_failure} after it
  # logged its `stream error:` line,
  # with the request's log context current ({Response#body_log_context}),
  # once per failed stream. A client that went away (EOFError, IOError,
  # Errno::ECONNRESET, Errno::EPIPE: what the server treats as a closed
  # peer) is not a failure and is not told.
  #
  # The HTTP layer names no error reporter: this base does nothing, and a
  # framework's error reporter installs a subclass that reports
  # ({SpinelHttp.stream_failure=}). An object with a method, not a stored
  # block, so Spinel resolves the call statically (NOTES.md rule 13).
  # @api public
  class StreamFailure
    # One writer's failure. The base does nothing. Must not raise.
    # @param error [Exception]
    # @return [nil]
    # @api public
    def stream_failed(error)
      nil
    end
  end

  # A module-level instance variable with a literal default, so Spinel
  # types the slot (NOTES.md rule 4).
  @stream_failure = StreamFailure.new

  # Where the Server tells a streamed body's failure: the base, which does
  # nothing, until an error reporter installs its reporting one.
  # @return [StreamFailure]
  # @api public
  def self.stream_failure
    @stream_failure
  end

  # Installs what the Server tells a streamed body's failure, at boot,
  # before any thread starts.
  # @param failure [StreamFailure]
  # @return [nil]
  # @api public
  def self.stream_failure=(failure)
    @stream_failure = failure
    nil
  end
end
