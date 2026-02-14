# Library Compatibility Test Results

## Summary

| Library           | Type         | Pass Rate | Status                      |
|-------------------|--------------|----------:|------------------------------|
| medley            | Utility      |     80.4% | Java interop = all failures  |
| camel-snake-kebab | Case convert |     98.6% | 2 fails = split edge case    |
| honeysql          | SQL DSL      |       N/A | GC crash during loading      |
| hiccup            | HTML         |  Skipped  | Heavy Java interop (URI etc) |
| clojure.data.json | JSON         |  Skipped  | Java IO based                |

### Key Findings

1. **Small pure-Clojure/cljc libraries work well** (98.6% CSK, 80% medley)
2. **Java interop is the primary failure cause** (all medley failures)
3. **GC crash blocks large namespaces** (honeysql ~1500 lines, CSK nested loops >60 iter)
4. **clojure.string/split trailing empties** — CW doesn't drop trailing empty strings

### Bugs Found and Fixed

| Bug | Fix |
|-----|-----|
| `^String []` return type hint on fn arities | `extractParamVector` helper in analyzer |
| `^:private ^:dynamic` nested metadata on def | Iterative with-meta unwrap loop |
| `p/Protocol` alias in extend-protocol/reify | `resolveQualified` fallback in VM+TreeWalk |
| `#?@` splicing reader conditional | `readReaderCondSplicing` in reader |

### Recommended Priority for Phase 72+

1. GC crash fix (blocks honeysql and heavy loops)
2. clojure.string/split trailing empty string behavior
3. Java interop remains out of scope (by design)

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
- GC crash occurs in heavy nested loops (>60 iterations with protocol dispatch);
  tests split into batches to work around. This is a pre-existing CW GC issue,
  not a library compatibility problem

## honeysql 2.6.x

Source: https://github.com/seancorfield/honeysql
Type: SQL DSL library (.cljc)

### Results

| Metric     | Value |
|------------|------:|
| Load       |  FAIL |
| Pass rate  |   N/A |

### Load Failure

honeysql's main namespace (honey.sql, ~1500 lines) triggers a GC crash during
loading. The crash occurs in the analyzer during macro expansion — a symbol name
string is garbage collected while still referenced.

Three bugs were found and fixed during the attempt:
1. `^String []` return type hints on multi-arity fn (analyzer)
2. `^:private ^:dynamic *var*` nested metadata on def (analyzer)
3. `p/Protocol` namespace alias in extend-protocol/reify (runtime)

After these fixes, loading progresses past the first ~400 lines but crashes
due to GC pressure from heavy macro expansion in the large namespace.

### Notes

- honey.sql.protocols loads successfully
- honey.sql.util loads successfully (after fix #1)
- honey.sql fails during loading (GC crash in analyzer, pre-existing issue)
- honey.sql has minimal Java interop (Locale/US for upper-case, UUID extension)
- Would likely work well once GC issues are resolved (Phase 72/73)
