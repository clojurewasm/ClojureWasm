# T11.6: Metadata + regex test suite

## Overview

Add compare-mode tests for metadata (T11.1-T11.2) and regex (T11.5)
builtins to eval_engine.zig. Verify VM/TreeWalk parity.

## Plan

### Step 1: Metadata compare-mode tests

Add to eval_engine.zig:

- `(meta [1 2])` => nil (no metadata)
- `(with-meta [1 2] {:tag :int})` => vector with metadata
- `(meta (with-meta [1 2] {:tag :int}))` => {:tag :int}
- `(vary-meta [1 2] assoc :x 1)` => vector with {:x 1}

### Step 2: Regex compare-mode tests

Add to eval_engine.zig:

- `(re-find (re-pattern "\\d+") "abc123")` => "123"
- `(re-find (re-pattern "\\d+") "abc")` => nil
- `(re-matches (re-pattern "\\d+") "123")` => "123"
- `(re-matches (re-pattern "\\d+") "abc123")` => nil
- `(re-seq (re-pattern "\\d+") "a1b22c333")` => ("1" "22" "333")
- `(re-find (re-pattern "(\\d+)-(\\d+)") "x12-34y")` => ["12-34" "12" "34"]

### Step 3: E2E file tests

Write .clj files and run via both backends to verify real Clojure-like behavior.

## Log

- Added 3 metadata compare-mode tests to eval_engine.zig:
  - meta on plain vector returns nil
  - with-meta attaches metadata (vector verified)
  - meta retrieves attached metadata (map verified)
- Added 6 regex compare-mode tests to eval_engine.zig:
  - re-find simple match ("123")
  - re-find no match (nil)
  - re-matches full match ("123")
  - re-matches partial returns nil
  - re-seq all matches (list of 3)
  - re-find with capture groups (vector of 3)
- E2E file tests: both backends produce identical output
  - Metadata: meta, with-meta, vary-meta all work
  - Regex: re-pattern, re-find, re-matches, re-seq all work
- All 9 new compare-mode tests pass
- All existing tests pass (no regressions)
