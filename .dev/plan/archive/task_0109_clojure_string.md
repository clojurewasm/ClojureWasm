# T13.3: clojure.string — join, split, upper-case, lower-case, trim

First non-clojure.core namespace. Implement commonly-used string functions
as Zig builtins in the clojure.string namespace.

## Plan

1. Create `src/common/builtin/clj_string.zig` with:
   - join (separator, coll) — join strings with separator
   - split (s, re-or-str) — split string (simple string split, not regex)
   - upper-case (s) — convert to uppercase
   - lower-case (s) — convert to lowercase
   - trim (s) — remove leading/trailing whitespace

2. Add BuiltinDef table with ns="clojure.string"

3. In registry.zig:
   - Import clj_string module
   - Add registerStringBuiltins function
   - Call from registerBuiltins

4. Add tests in clj_string.zig

5. Integration test: eval clojure.string functions

## Log

- Created src/common/builtin/clj_string.zig with 5 builtins
- join (1-2 arity), split (string pattern), upper-case, lower-case, trim
- Registered in clojure.string namespace via registry.zig
- Fixed resolveVar to fall back to env namespace lookup for qualified symbols
- All Zig tests pass, SCI 72/74 pass
- vars.yaml: 5 clojure.string functions marked done (273/702)
