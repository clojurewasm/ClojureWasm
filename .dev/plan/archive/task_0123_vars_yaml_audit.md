# T15.0: vars.yaml Audit

## Goal

Audit and fix vars.yaml to accurately reflect current implementation status.
Ensure done/todo/skip status and notes are correct for all clojure.core vars.

## Current State (Verified)

### vars.yaml counts

- done: 269
- todo: 428
- skip: 7
- Total: 704

### Actual implementation sources

- Builtin functions (clojure.core only): 156
- core.clj definitions: 110
- Special forms (analyzer.zig): 21
- Total unique clojure.core: 267

### Non-clojure.core implementations (excluded from audit)

- clojure.string builtins: 14 (join, split, upper-case, lower-case, etc.)
- clojure.walk: 5 (walk, postwalk, prewalk, postwalk-replace, prewalk-replace)
- clojure.template: 2 (apply-template, do-template)
- Internal: 1 (lazy-cat-helper)

## Audit Results

### Verification complete ✓

1. **269 marked done** = 267 implemented + catch + finally (part of try)
2. **No false positives**: All done items are actually implemented
3. **No false negatives**: All implemented items are marked done
4. **catch/finally correctly done**: Part of try special form

### Issues fixed during audit

- fn, let, loop: Changed from todo → done (special forms via fn*, let*, loop\*)

### Notes verification

- `catch`: type=special-form, status=done
- `finally`: type=special-form, status=done, note="part of try"

## Log

### Session 1 (completed)

1. Extracted builtins from src/common/builtin/\*.zig (excluding clj_string.zig)
2. Extracted defn/defmacro from src/clj/core.clj
3. Extracted special forms from src/common/analyzer/analyzer.zig
4. Cross-referenced with vars.yaml using yq
5. Fixed fn, let, loop status (todo → done)
6. Verified catch/finally are correctly marked done
7. Confirmed no discrepancies remain
