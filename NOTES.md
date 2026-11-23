# Spinel constraints for spinel-http

spinel-http builds and passes its tests under upstream Spinel (matz/spinel,
2026.10.25) and under the fork (saeki-mototsune/spinel, 2026.11.15.7033). A
workaround that upstream needs is taken even where the fork does not need it.
Each rule names the upstream issue it comes from.

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
