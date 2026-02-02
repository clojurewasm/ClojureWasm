# T7.6: Lazy Sequences — lazy-seq, lazy-cat

## Goal

Implement lazy sequences: lazy-seq macro and LazySeq value type.
This enables idiomatic Clojure patterns like infinite sequences,
lazy map/filter, iterate, repeat, etc.

## Design

### LazySeq Value Type

LazySeq = { thunk: ?fn_val, realized: ?Value }

- thunk: A zero-arg function that produces a sequence (cons/list/nil)
- realized: Cached result after first realization
- On access (first, rest, seq): realize thunk if not yet done

### Implementation Strategy

Rather than full Clojure ISeq protocol, use a simpler approach:

- LazySeq wraps a thunk (fn of 0 args -> seq-like value)
- `seq` on LazySeq realizes the thunk and returns result
- `first`/`rest` on LazySeq delegates through `seq`
- lazy-seq macro wraps body in (fn [] body)

### Components

1. **Value**: Add LazySeq struct + lazy_seq variant
2. **core.clj**: Add lazy-seq macro (wraps body in fn)
3. **TreeWalk**: Handle lazy_seq in first/rest/seq/count
4. **Builtins**: seq, first, rest need to realize lazy seqs
5. **Bootstrap**: Tests with lazy-seq, iterate, take

## Plan (TDD)

1. Red: Test (take 5 (iterate inc 0)) => [0 1 2 3 4]
2. Green: Implement LazySeq + lazy-seq + realize in builtins
3. Refactor

## Log
