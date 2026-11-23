# Spinel constraints for spinel-http

spinel-http builds and passes its tests under upstream Spinel (matz/spinel,
2026.10.25) and under the fork (saeki-mototsune/spinel, 2026.11.15.7033). A
workaround that upstream needs is taken even where the fork does not need it.
Each rule names the upstream issue it comes from, where one is filed.

## Rules

1. **A call that answers nil is a statement, its result asserted after
   (never an argument).** Under upstream 2026.10.25 a call of a method that
   always answers nil, written as the argument of a parameter typed
   otherwise, compiles to `NULL`: the call and its side effects are gone.
   `assert_nil res.drop_header("Location")` became `sp_assert_nil(NULL)`, so
   the header stayed and the next assertion failed. Write
   `dropped = res.drop_header("Location")`, then `assert_nil dropped`.
   Fixed in matz/spinel after the tag (matz/spinel#10260); kept until the
   CI's upstream tag includes it.

2. **A nil-valued local is not passed to an assertion whose other callers
   pass an Integer.** Under upstream 2026.10.25, in one program,
   `value = nil; assert_nil value` beside `assert_nil 3` raised
   `TypeError: nil can't be coerced into Integer` at the call; the literal
   `assert_nil nil` works, and so does a String. Seen while testing the
   helper (test/check.rb); no upstream issue filed yet (same family as
   rule 1). The fork is not affected.

## Rules the moved code was written to

The rules below were found while the layer was written against earlier
Spinel builds (2026.09.12 and the fork's 2026.11.04.7026, before the
2026.10.25 upstream tag); some reduced probes pass on later builds, but the
code keeps each workaround for the shape it was written for. None has an
upstream issue filed yet. A comment in the code cites the rule it follows as
"NOTES.md rule N".

3. **Read a String parameter through a new `to_s` local before byte
   methods.** A method defined in Ruby source under a builtin's name
   (`getbyte`, `read`, `write`, `<<`, `keys`) makes every call of that name
   on a *boxed* receiver a switch over the classes that define it, with
   NoMethodError as the default and no fallback to the builtin. Spinel's
   openssl package defines `getbyte` (OpenSSL::Buffering), so in a program
   that requires it `s.getbyte(i)` on a boxed String raises "undefined
   method 'getbyte' for an instance of String". A String parameter is boxed
   when one caller passes a nullable or boxed value (a header lookup that can
   answer nil, a key of an unseeded Hash). So every method that scans a
   network String byte by byte starts with `s = text.to_s` (for a String it
   is the String itself, no copy). Reassigning the parameter
   (`text = text.to_s`) does not help: it keeps the boxed slot. The same
   hazard is why Response#drop_header iterates with `each_key`, not
   `keys.each`, and why Params has no `keys` method.

4. **A class-level setting is a module-level ivar with a literal default,
   read and written through `def self.` accessors, never `@@`.** A `@@x`
   assigned in a module an earlier file already opened failed to compile
   (`use of undeclared identifier 'cvar_...'`), and `@@x` is not a GC root
   (an object only it held was collected). The literal default types the
   slot. This is the shape of `Params.max_page`, `Request.inflater`,
   `Request.trusted_proxy`, `ClientError.extra_faults`,
   `HttpLogSwitch.installed_switch`, `GzipDecoder.installed`,
   `Multipart.configure`, `Response.default_permissions_policy` and
   `SpinelHttp.stream_failure`.

5. **Seed containers with their element type, and use typed sentinels
   instead of nil.** An empty Array or Hash stored in an ivar is built as
   `Array.new(0) { "" }` or `{ "" => x }` then emptied; a bare `{}` has
   untyped keys, which reach rule 3's byte scans boxed. A local or ivar that
   starts as nil and later holds a String or an Integer widens the method to
   the boxed path, and an ivar of a Time that starts as nil read back
   `Time.at(0)`: use `""`, `-1` or a flag (`Cookies::NO_EXPIRES` is a Time
   standing for "none", not nil).

6. **One method name, one return type across the whole program.** Two
   methods sharing a name on unrelated classes with different return types
   corrupted inference ("emit_boxed_text: cannot box type"), and a shared name
   on a polymorphic receiver corrupted the inferred return type. A program
   built on the layer shares this namespace, so the layer's names are
   distinctive (`installed_switch`, not `installed`; `status_for`, not
   `status`), and `redirect` and `drop_header` answer nil. Not every clash
   breaks a program: class methods sharing a name with other return types
   have compiled and run, and the layer ships one such set, `parse`
   (`Cookies.parse` a Hash, `Query.parse` a Params, `Multipart.parse` a
   MultipartForm). That set is a record, not a precedent: the rule stands
   for new code, and if a compiler refuses the set the remedy is a prefixed
   name (`cookies_parse`).

7. **Offsets into request text are bytes, and the text is validated as UTF-8
   once, first.** Spinel indexes a String holding non-ASCII text by
   character, so `index`/`[]`/`size` over a buffer shift the framing of a
   pipelined request and cost O(offset) per call; use
   `byteindex`/`byteslice`/`bytesize`. CRuby's `byteindex` raises IndexError
   for an offset inside a character of an invalid String, where Spinel's
   does not check, so Query.utf8! validates the text once (QueryMalformed),
   and every later offset is on a character boundary.

8. **A String built in a loop starts as `+""` and grows with `<<`; it is
   returned, not filled through a parameter.** A local appended to in a loop
   is compiled as a growable buffer: a String *assigned* to it is copied with
   strlen, losing everything after the first NUL byte (a gzip upload's body
   was cut), and interpolating a String that holds a NUL truncates it the same
   way. A local a method appends to directly loses what helpers appended to it
   through a parameter in the same method.

9. **Percent-decoding checks its own escapes and hands the library decoder
   only runs of `%XX`.** `URI.decode_www_form_component` decoded a malformed
   escape (`%ZZ`, a trailing `%`) silently under Spinel 2026.09.12 where CRuby
   raised, and it is quadratic on a String that holds non-ASCII text (8.5 s
   for e-acute + 200 000 bytes; linear under CRuby). Query.decode_valid checks
   each escape itself and copies the text between escapes with byteslice.

10. **Request digits are length-checked before `to_i`.** Spinel's
    `String#to_i` raises RangeError past 2**63-1 instead of answering a
    Bignum, so a 20-digit parameter or Content-Length would be a 500. Read at
    most 18 digits (Params.parse_int, Request#content_length,
    Server#body_length).

11. **A `rescue` lives in a plain, non-yielding method; a block is stored and
    called with `.call`.** A `begin/rescue => e` (or a second `ensure`) inside
    a yielding method called from a block nested in another block failed to
    compile ("assigning to 'volatile sp_RbVal' from incompatible type"), and a
    method that takes `&block` and calls it is inlined like a yielding one.
    `yield self` in a base-class method called on a subclass failed at the C
    level. So the server's rescues (run_writer, accept_queued_client) are in
    methods that take no block, and BlockWriter stores its block and calls it
    from `write_body`.

12. **Exceptions are told apart by their full class name, not by `is_a?` or
    `superclass`.** On Spinel 2026.09.12 `is_a?` on a rescued exception
    answered false for its own superclass, and a raised QueryTooMany's class
    chain was QueryTooMany, Object, BasicObject. Later builds answer correctly
    for classes the program defines, but `superclass` still raises
    NoMethodError for a package's exception class and, in a program that
    defines a module, for Ruby's own. So ClientError compares
    `e.class.name` with CLIENT_FAULTS and `extra_faults`.

13. **A hook is a base class with a stub method, and an installed hook is an
    object, not a stored block.** A base method that calls a method only
    subclasses define crashed the compiler; a base stub fixes the directly
    dispatched case (HttpHandler#call, BodyWriter#write_body,
    StreamFailure#stream_failed, the HttpLog methods). A stored block called
    with a base-class receiver ran the base's method, not the subclass's
    override, so what the layer calls back (the stream-failure sink, the log
    switch) is an object with a method. A lambda passed as a keyword argument
    received garbage parameters: a lambda (Request.inflater) is passed
    positionally.

14. **Sockets: `wait_readable` before every `readpartial`, and a socket
    reaches a thread through a method parameter.** `readpartial` is a raw
    blocking read that holds the OS worker; `wait_readable` parks the green
    thread, and its nil answer is the idle timeout. A socket passed as a
    `Thread.new` argument lost its static type ("undefined method
    'wait_readable' for TCPSocket"): spawn through a method whose parameter
    the block captures (Server#spawn_serve).

15. **One Spinel worker, and no lock taken per request.** For an I/O-bound
    server `SPINEL_WORKERS=1` was faster than several workers and had no
    40-80 ms stalls; Server#start sets it before the first `Thread.new`
    unless the program set it. A `Mutex#synchronize` taken on every request
    stalled requests for seconds with two workers; the server's lock is taken
    when a connection opens and closes only.

16. **Swap a thread's context with save, work, restore in `ensure`, and no
    `rescue` beside it.** A method that saves a value, yields or calls into a
    local, restores in `ensure` and returns the local compiles and restores
    for blocks that answer or raise; a rescue in such a yielding method hits
    rule 11. This is BodyWriter.write_scoped, Server#run_writer_scoped and
    Server#classify_scoped.

17. **A key is named with `Symbol#name`, never `Symbol#to_s`, and one
    method is not fed both Symbol and String keys in a test program.**
    `Symbol#to_s` answers a new frozen String at every call, and a frozen
    heap String is never freed: every `sym.to_s` on a request path leaked
    about 110 bytes (fork 2026.11.15.7033). Key.string_of answers the
    Symbol's one cached name. Separately, one program calling a method with
    both Symbol and String keys mis-dispatched the `key.to_s` inside it
    ("no implicit conversion of Symbol into String"), so a test program keeps
    to one key type per method.

18. **A failure that crosses an optional file is a status, not an exception
    class.** A `rescue` arm naming a qualified class the program does not
    define resolves by its last segment: it never matches, or turns the whole
    `begin`/`rescue` into a catch-all that runs no arm when another class has
    that last segment. So GzipDecoder reports a failure through
    `gzip_status`, and its caller raises its own error, naming no class of
    the gzip support, which may not be in the program.

19. **An FFI out-parameter is a fresh `malloc(8)` slot per call, never a
    static `ffi_buffer`.** The C side writes the address of its output
    buffer through the slot; a slot shared across calls would be overwritten
    by the next one. GzipDecoder allocates a slot for each call.
