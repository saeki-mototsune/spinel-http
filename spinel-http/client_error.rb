require "json"
require "spinel-http/extra_faults"
require "spinel-http/query"
require "spinel-http/response"

module SpinelHttp
  # The one place that says which exceptions out of the app are the client's
  # fault and what status they get. Server#respond, and any error page a
  # framework puts in front of it, catch everything the app raises and ask
  # here first, so a new client-fault class (a body-size or multipart limit,
  # say) is added once and every path answers alike instead of one of them
  # quietly answering 500.
  module ClientError
    # The status for an exception out of the app, logged at the level it
    # deserves: a client fault (request parameters past Query's limits or
    # not decodable, QueryInvalid; or a class in {.extra_faults}, such as a
    # framework's missing-required-parameter error) is its 4xx at info, so
    # a flood of them does not fill the error log; anything else is 500 at
    # error, as `class: message`. Each error path then does
    # `reset_to(status)` (or its own 500 page); the layer's next
    # client-fault class is added to CLIENT_FAULTS below and nowhere else,
    # and one defined outside the layer to {.extra_faults}.
    # @param e [Exception]
    # @param logger [HttpLog] the Server's sink, the base or a subclass
    # @return [Integer] 400 or 500 ({.status_for})
    def self.classify(e, logger)
      status = self.status_for(e)
      if status >= 500
        logger.error("#{e.class.name.to_s}: #{e.message}")
      else
        logger.info("rejected request (#{status} #{Response.status_text(status)}): #{e.message}")
      end
      status
    end

    # Full class names of the client-fault exceptions: THE list, and the one
    # place to add a new one (a new QueryInvalid subclass, say). The list
    # stands in for `e.is_a?(QueryInvalid)`: on Spinel 2026.09.12 is_a? on an
    # exception object answered false for its own superclass (a QueryTooDeep
    # reached every error path as a 500), and a raised QueryTooMany's class
    # chain was QueryTooMany, Object, BasicObject. Later builds answer as
    # CRuby does in small programs of both shapes for classes the program
    # defines, while `superclass` still raises NoMethodError on a package's
    # exception class and, in a program that defines a module, on Ruby's own.
    # The list stays until a change replaces it with a compiled test of these
    # error paths. A framework's own handlers can match by class name the same
    # way.
    #
    # Every subclass must be listed by its full name, which is what
    # ClientError.status_for compares. An app's own exception class, even
    # one that subclasses QueryLimitExceeded, is the app's 500; the list is the
    # layer's.
    CLIENT_FAULTS = ["SpinelHttp::QueryInvalid", "SpinelHttp::QueryLimitExceeded",
                     "SpinelHttp::QueryTooDeep", "SpinelHttp::QueryTooMany",
                     "SpinelHttp::QueryMalformed",
                     "SpinelHttp::BodyUndecodable", "SpinelHttp::BodyTooLarge",
                     "SpinelHttp::MultipartMalformed", "SpinelHttp::MultipartTooManyParts",
                     "SpinelHttp::MultipartPartTooLarge", "SpinelHttp::MultipartHeaderTooLarge"]

    # {.extra_faults} and {.extra_faults=}, the client faults defined
    # outside the layer, are in spinel-http/extra_faults.rb, which a
    # library that registers one can load without the rest of the layer.

    # 400 for a client fault (CLIENT_FAULTS or {.extra_faults}), 500 for
    # the app's own exception: an Array lookup, no raise, so a request
    # logger (for its completion line) and every error path (an error page,
    # Server#respond) can each ask and always agree. `to_s`: Class#name is
    # nil for an anonymous class (`Class.new(StandardError)`) under CRuby,
    # and this runs inside error handlers' rescue clauses, where a
    # NoMethodError would escape and close the connection with no response
    # at all. Named status_for, not status: other classes in one program
    # define `status` with other return types.
    # @param e [Exception]
    # @return [Integer] 400 or 500
    def self.status_for(e)
      name = e.class.name.to_s
      return 400 if fault_name_in?(name, CLIENT_FAULTS)
      return 400 if fault_name_in?(name, extra_faults)

      500
    end

    # Whether name is one of names. A while loop, not a block: no closure,
    # nothing to widen.
    # @param name [String]
    # @param names [Array<String>]
    # @return [Boolean]
    # @api private
    def self.fault_name_in?(name, names)
      i = 0
      while i < names.length
        return true if names[i] == name
        i += 1
      end
      false
    end
  end
end
