# Library Compatibility Test Results

## Summary

| Library           | Type         | Pass Rate | Status                      |
|-------------------|--------------|----------:|------------------------------|
| medley            | Utility      |     80.4% | Java interop = all failures  |
| camel-snake-kebab | Case convert |     98.6% | 2 fails = split edge case    |
| honeysql          | SQL DSL      |      Load | All 3 namespaces load OK     |
| hiccup            | HTML         |  Skipped  | Heavy Java interop (URI etc) |
| clojure.data.json | JSON         |    100.0% | CW fork, 51 tests, 80 assertions |

### Key Findings

1. **Small pure-Clojure/cljc libraries work well** (98.6% CSK, 80% medley)
2. **Java interop is the primary failure cause** (all medley failures)
3. **clojure.string/split trailing empties** — CW doesn't drop trailing empty strings
4. **GC crash resolved** (Phase 72.1) — honeysql loads, CSK nested loops pass 200 iterations

### Bugs Found and Fixed

| Bug | Fix | Phase |
|-----|-----|-------|
| `^String []` return type hint on fn arities | `extractParamVector` helper in analyzer | 71 |
| `^:private ^:dynamic` nested metadata on def | Iterative with-meta unwrap loop | 71 |
| `p/Protocol` alias in extend-protocol/reify | `resolveQualified` fallback in VM+TreeWalk | 71 |
| `#?@` splicing reader conditional | `readReaderCondSplicing` in reader | 71 |
| GC crash during macro expansion (6 root causes) | D100: string duplication, cache tracing, GC suppression | 72.1 |
| char `.toString` method not implemented | `javaMethodFn` char handler | 72.1 |
| fn name with metadata `(with-meta name meta)` | `analyzeFn` name pattern matching | 72.1 |

### Recommended Priority

1. clojure.string/split trailing empty string behavior
2. Java interop remains out of scope (by design)

---

## medley 1.8.0+

Source: https://github.com/weavejester/medley
Type: Pure Clojure utility library (.cljc)

### Results

| Metric     | Value |
|------------|------:|
| Tests      |    53 |
| Assertions |   276 |
| Pass       |   222 |
| Fail       |     5 |
| Error      |    49 |
| Pass rate  | 80.4% |

### Failure Categories

| Category              | Count | Examples                               |
|-----------------------|------:|----------------------------------------|
| Java interop methods  |    25 | .indexOf, .getMessage, .add, .size     |
| Java constructors     |    16 | java.util.ArrayList., new Exception    |
| Java static methods   |     5 | UUID/fromString, UUID/randomUUID       |
| Java class types      |     5 | PersistentQueue, java.util.UUID        |
| Missing features      |     3 | uuid? (CW UUIDs are strings)           |

### Passing Function Groups (100%)

find-first, dissoc-in, assoc-some, update-existing, update-existing-in,
map-entry, map-kv, map-keys, map-vals, map-kv-keys, map-kv-vals,
filter-kv, filter-keys, filter-vals, remove-kv, remove-keys, remove-vals,
boolean?, least, least-by, greatest, greatest-by, join, deep-merge,
mapply (partial), collate-by, index-by, interleave-all, distinct-by,
dedupe-by, take-upto, drop-upto, abs, deref-swap!, deref-reset!,
regexp?, find-in

### Failing Function Groups

| Function         | Reason                                         |
|------------------|------------------------------------------------|
| queue/queue?     | CW no PersistentQueue (instance? check fails)  |
| partition-after  | java.util.ArrayList constructor in :clj branch |
| partition-before | java.util.ArrayList constructor in :clj branch |
| partition-between| java.util.ArrayList constructor in :clj branch |
| window           | java.util.ArrayList constructor in :clj branch |
| index-of         | .indexOf Java interop method on collections    |
| ex-message       | .getMessage Java interop on exceptions          |
| ex-cause         | new Exception constructor syntax               |
| uuid/uuid?       | java.util.UUID type (CW UUIDs are strings)     |
| random-uuid      | java.util.UUID/randomUUID static method         |

### Notes

- All failures are due to Java interop that CW doesn't support
- The core map/filter/reduce utility functions work perfectly
- Reader conditionals (#? and #?@) work correctly
- defrecord works correctly (MyRecord tests pass)
- Transducer support works for non-Java-interop functions

## camel-snake-kebab 0.12.0+

Source: https://github.com/clj-commons/camel-snake-kebab
Type: Case conversion library (.cljc)

### Results

| Metric     | Value  |
|------------|-------:|
| Tests      |      4 |
| Assertions |    147 |
| Pass       |    145 |
| Fail       |      2 |
| Error       |      0 |
| Pass rate  | 98.6%  |

### Failure Details

| Test                     | Reason                                               |
|--------------------------|------------------------------------------------------|
| separator-only (2 cases) | clojure.string/split doesn't drop trailing empties   |

`(csk/->kebab-case "a" :separator \a)` returns `"-"` instead of `""`.
Root cause: CW's `clojure.string/split` returns `["" ""]` for `(split "a" #"a")`
while upstream Clojure returns `[]` (Java's Pattern.split drops trailing empties).

### Passing Function Groups (100%)

**Type-preserving conversions**: ->PascalCase, ->camelCase, ->SCREAMING_SNAKE_CASE,
->snake_case, ->kebab-case, ->Camel_Snake_Case, ->HTTP-Header-Case
(all work correctly on strings, keywords, and symbols)

**Type-converting conversions**: ->PascalCaseKeyword, ->camelCaseString,
->SCREAMING_SNAKE_CASE_STRING, ->snake_case_keyword, ->kebab-case-symbol, etc.

**Extras**: transform-keys (including metadata preservation)

**Error handling**: Namespaced keyword/symbol rejection via ex-info

### Notes

- All namespaces load successfully (string-separator, misc, alter-name, macros, core, extras)
- Protocol dispatch (AlterName, StringSeparator) works correctly
- defconversion macro (macro-generated defns) works correctly
- reify works correctly (generic-separator)
- extend with letfn-defined functions works correctly
- HTTP header special cases (DNT, SSL, XSS, etc.) all correct
- with-meta preservation through postwalk works
- GC crash in heavy nested loops fixed (Phase 72.1, D100). Protocol dispatch
  stress test now passes 200 iterations cleanly.

## honeysql 2.6.x

Source: https://github.com/seancorfield/honeysql
Type: SQL DSL library (.cljc)

### Results

| Metric     | Value |
|------------|------:|
| Load       |  PASS |
| Namespaces |   3/3 |

All three namespaces load successfully on both VM and TreeWalk:
- honey.sql.protocols
- honey.sql.util
- honey.sql (main namespace, ~1500 lines)

### Bugs Fixed During Testing

Phase 71:
1. `^String []` return type hints on multi-arity fn (analyzer)
2. `^:private ^:dynamic *var*` nested metadata on def (analyzer)
3. `p/Protocol` namespace alias in extend-protocol/reify (runtime)

Phase 72.1:
4. GC crash during macro expansion (6 root causes, D100)
5. char `.toString` Java interop method
6. fn name with `(with-meta name meta)` from defn macro

### Notes

- honeysql has minimal Java interop (Locale/US for upper-case, UUID extension)
- Test suite not yet ported (would need honeysql test dependencies)
- Loading success validates: macro expansion, protocol dispatch, large
  namespace handling, reader conditionals, GC stability

## clojure.data.json (CW fork)

Source: CW-compatible fork of https://github.com/clojure/data.json
Type: JSON parser/generator
Location: `src/clj/clojure/data/json.clj` (embedded in binary, lazy-loaded)

### Results

| Metric     | Value |
|------------|------:|
| Tests      |    51 |
| Assertions |    80 |
| Pass       |    80 |
| Fail       |     0 |
| Error      |     0 |
| Pass rate  |  100% |

### Approach

Upstream data.json is deeply Java-intertwined (definterface, deftype with mutable
fields, PushbackReader, StringWriter, char-array, short-array). A CW-compatible
fork was created replacing:

| Java Construct           | CW Replacement                          |
|--------------------------|----------------------------------------|
| definterface + deftype   | defprotocol + reify with volatile!     |
| StringWriter/Appendable  | Protocol-based string builder (vector) |
| char-array/short-array   | Seq iteration over codepoints          |
| Integer/parseInt radix   | Pure Clojure hex digit parser          |
| Java type extends        | CW type names (Long, String, etc.)     |
| case with 8+ kw branches | condp = (CW case hash collision bug)   |

### API Coverage

| Function    | Status | Notes                         |
|-------------|--------|-------------------------------|
| read-str    | Pass   | Full feature support          |
| write-str   | Pass   | Full feature support          |
| read-json   | Pass   | Deprecated compat wrapper     |
| json-str    | Pass   | Deprecated compat wrapper     |
| read        | Skip   | Needs java.io.Reader          |
| write       | Skip   | Needs java.io.Writer          |
| pprint      | Skip   | Needs PrintWriter             |

### Bugs Fixed During Implementation

| Bug | Fix | Component |
|-----|-----|-----------|
| `(int \a)` returns error | Add char→int cast in intCoerceFn | arithmetic.zig |
| Unicode writer escapes bytes not codepoints | Use `doseq` over `(seq s)` instead of `dotimes`+`.charAt` | json.clj |
| UUID write produces map JSON | Check `uuid?` before `map?` in Object catch-all | json.clj |
| `case` macro hash collision with 8+ keywords | Use `condp =` workaround | json.clj |

### Notes

- `(int \a)` → 97 now works (needed by many libraries)
- CW's `.charAt` returns UTF-8 bytes, not Unicode codepoints; `(seq s)` gives codepoints
- CW's UUID class has `(map? uuid)` = true; writer checks `uuid?` first
- `case` macro has a hash collision bug with 8+ keyword branches (tracked, not fixed)
