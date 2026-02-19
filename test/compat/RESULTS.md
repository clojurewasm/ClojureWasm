# Library Compatibility Test Results

## Purpose

Test real-world Clojure libraries **as-is** on ClojureWasm. Libraries are NOT forked
or embedded — they are loaded from their original source, and their tests are run
unmodified. When CW behavior differs from upstream Clojure, trace CW's processing
pipeline (reader → analyzer → compiler → VM/TreeWalk → builtins) to find and fix
the root cause. Library tests serve as a specification of correct Clojure behavior.

## Summary

| Library           | Type         | Pass Rate | Status                      |
|-------------------|--------------|----------:|------------------------------|
| medley            | Utility      |     80.4% | Java interop = all failures  |
| camel-snake-kebab | Case convert |     98.6% | 2 fails = split edge case    |
| honeysql          | SQL DSL      |      Load | All 3 namespaces load OK     |
| hiccup            | HTML         |  Skipped  | Heavy Java interop (URI etc) |
| tools.cli         | CLI parsing  |      4/6  | 2 pass, 3 partial, 1 crash   |
| instaparse        | Parser gen   |     9/16  | Blocked by deftype           |
| data.csv          | CSV I/O      |     100%  | Full read/write working      |
| data.json         | JSON I/O     |  Blocked  | Needs definterface/deftype   |
| meander           | Pattern match|     6/18  | &form, case*, macro issues   |
| core.match        | Pattern match|  Blocked  | deftype + clojure.lang       |

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
| `re-seq` returns `()` instead of `nil` for no matches | Return `nil` in `reSeqFn` when results empty | 75.6 |
| `s/join` fails on lazy-seq realizing to cons | Handle `.cons` in `joinFn` lazy_seq branch | 75.6 |
| `\b` and `\f` string escapes not supported | Added to `unescapeString` in reader | 75.C |
| `^Type` hints on defrecord fields fails | with-meta unwrap in `analyzeDefrecord` | 75.C |
| Prefix-list require `(:require (prefix [lib]))` | `.list` case in `requireFn` | 75.F |
| Protocol dispatch fails on class instances | `mapTypeKey` FQCN mapping for Java classes | 75.F |
| `ns` with `^:no-doc` + docstring fails set-ns-doc | with-meta unwrap in `setNsDocFn` | 75.G |

### Known CW Limitations (discovered via library testing)

| Limitation | Affected Libraries | Severity | Status |
|------------|-------------------|----------|--------|
| ~~Regex engine lacks backtracking~~ | tools.cli, general | High | **FIXED 75.A.3** |
| ~~`clojure.string/split` trailing empties~~ | CSK | Medium | **Already correct** |
| ~~`(apply map vector colls)` doesn't work~~ | tools.cli | Medium | **FIXED 75.A.2** |
| ~~`(catch Exception e)` without body fails~~ | tools.cli | Low | **FIXED 75.A.1** |
| ~~Reader conditional elision in collections~~ | tools.cli | Medium | **FIXED 75.B** |
| ~~`^Type` hints in for/let/doseq bindings~~ | tools.cli | Medium | **FIXED 75.B** |
| `Long/parseLong` returns nil instead of throwing | tools.cli | Low | Open |
| `case` macro hash collision with 8+ keyword branches | data.json | Low | Open (F139) |
| `(char int)` returns string, not char type | data.csv | Low | Open |
| ~~`\b` and `\f` string escapes not supported~~ | instaparse | Low | **FIXED 75.C** |
| ~~`^Type` hints on defrecord fields~~ | instaparse | Medium | **FIXED 75.C** |
| `deftype` not implemented (permanently skipped) | instaparse | High | Won't fix |
| ~~Protocol dispatch on class instances~~ | data.csv | High | **FIXED 75.F** |
| ~~Prefix-list require format~~ | data.csv | Medium | **FIXED 75.F** |
| `definterface` not implemented | data.json | High | Open |
| `&form` implicit macro binding not available | meander | Medium | Open |
| GC crash under heavy allocation (keyword pointer freed) | tools.cli | High | Resolved (no longer reproducible) |

### Java Interop Gaps (blocking library tests)

| Java Class/Method | Libraries Needing It | Priority |
|-------------------|---------------------|----------|
| ~~PushbackReader~~ | ~~data.json, data.csv, edn~~ | **DONE 75.D** |
| ~~StringWriter/StringBuilder~~ | ~~data.json, data.csv~~ | **DONE 75.D** |
| java.util.ArrayList | medley (partition-*) | Medium |
| .indexOf on collections | medley | Low |
| .getMessage on exceptions | medley | Low |

### Recommended Priority

1. Regex backtracking (high impact, many libraries will hit this)
2. PushbackReader / StringWriter interop shims (unblocks data.json, data.csv)
3. clojure.string/split trailing empty string behavior
4. `(apply map f colls)` pattern fix

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
| Error      |      0 |
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

## tools.cli

Source: https://github.com/clojure/tools.cli
Type: .cljc with reader conditionals

### Results

| Test                     | Status  | Fails |
|--------------------------|---------|------:|
| test-tokenize-args       | PASS    |     0 |
| test-get-default-options | PASS    |     0 |
| test-compile-option-specs| Partial |     1 |
| test-parse-option-tokens | Partial |     5 |
| test-summarize           | CRASH   |     - |
| test-parse-opts          | Partial |     3 |

### Bugs Fixed During Testing

Phase 75 (previous): re-seq nil return, s/join lazy-seq cons handling
Phase 75.A.1: `(catch Exception e)` empty body
Phase 75.A.2: `(apply map vector colls)` exact-arity dispatch
Phase 75.A.3: Regex greedy backtracking (`(.*)a`, `(\S+)=(.+)`, etc.)
Phase 75.B: Reader conditional elision in collections (`#?(:cljs x)` → nil)
Phase 75.B: `^Type` hints in for/let/doseq bindings

### Remaining Issues

- `test-summarize` GC crash: segfault in `dissocFn` keyword comparison (F140)
- `:validate` desugaring: `[seq "msg"]` pairs resolve to nil
- Some parse-fn/validate-fn interactions fail

### Notes

- Library loads and basic parse-opts works correctly
- No Java interop needed — all failures are CW behavioral issues
- GC crash is pre-existing (keyword pointer freed under allocation pressure)

## instaparse 1.5.x

Source: https://github.com/Engelberg/instaparse
Type: GLL parser generator (.cljc, ~3000 LOC)

### Results

| Metric      | Value |
|-------------|------:|
| Modules     | 16    |
| Load OK     |     9 |
| Load FAIL   |     7 |
| Load rate   | 56.3% |

### Module Loading Status

| Module              | Status | Reason                              |
|---------------------|--------|-------------------------------------|
| util                | OK     |                                     |
| print               | OK     | (after `\b`/`\f` fix)              |
| auto-flatten-seq    | FAIL   | `deftype` not implemented           |
| reduction           | OK     |                                     |
| combinators-source  | OK     |                                     |
| failure             | OK     |                                     |
| gll                 | FAIL   | `deftype` not implemented           |
| transform           | OK     |                                     |
| line-col            | OK     | (after defrecord type hint fix)     |
| repeat              | FAIL   | `instaparse.viz` not on require path|
| cfg                 | FAIL   | Depends on gll (cascading)          |
| abnf                | FAIL   | Depends on cfg (cascading)          |
| macros              | OK     |                                     |
| combinators         | FAIL   | Depends on cfg/abnf (cascading)     |
| viz                 | OK     |                                     |
| core                | FAIL   | Depends on everything (cascading)   |

### Primary Blockers

1. **`deftype` (permanently skipped)**: `auto_flatten_seq.cljc` and `gll.cljc` define custom
   types (`AutoFlattenSeq`, `FlattenOnDemandVector`, `Failure`) using `deftype` with heavy
   JVM interface implementations (`clojure.lang.ISeq`, `clojure.lang.Counted`, etc.).
   These are core data structures — the library cannot function without them.

2. **STM (`ref`/`dosync`/`ref-set`)**: Used in `FlattenOnDemandVector` for lazy flattening.

3. **`compile-if` macro**: Uses `(eval test)` at macro expansion time for backwards compatibility.

### Bugs Fixed During Testing

| Bug | Fix |
|-----|-----|
| `\b` and `\f` string escapes not recognized | Added to `unescapeString` in reader.zig |
| `^int`/`^long` type hints on defrecord fields | with-meta unwrap in `analyzeDefrecord` |

### Notes

- The 9 modules that load represent utility, combinators, reduction, and transformation layers
- The GLL parsing engine (`gll.cljc`) and its core data structures (`auto_flatten_seq.cljc`)
  are blocked by `deftype` — these are fundamental to the library's operation
- `deftype` is permanently skipped in CW (design decision: defrecord covers data use cases)
- Conclusion: **instaparse is out of scope** due to `deftype` dependency

---

## data.csv 1.1.x

Source: https://github.com/clojure/data.csv
Type: CSV reader/writer (.clj)

### Results

| Metric   | Value |
|----------|------:|
| Load     |  PASS |
| read-csv |  PASS |
| write-csv|  PASS |

All features working:
- Basic CSV parsing (comma-separated)
- Custom separators (`;`, `\t`, etc.)
- Quoted fields with embedded commas and escaped quotes
- Multi-row parsing with lazy sequences
- write-csv to StringWriter
- Empty field handling

### Bugs Fixed During Testing

| Bug | Fix |
|-----|-----|
| Prefix-list require `(:require (clojure [string :as str]))` | `.list` case in `requireFn` (ns_ops.zig) |
| Protocol dispatch on class instances (PushbackReader) | `mapTypeKey` short→FQCN mapping (vm.zig, tree_walk.zig) |

### Notes

- Library uses `extend-protocol` on `PushbackReader` and `String` — requires Phase 75.D interop shims + Phase 75.F protocol dispatch fix
- Both read and write APIs work on both VM and TreeWalk backends
- No modifications needed to the library source

## meander (epsilon)

Source: https://github.com/noprompt/meander
Type: Pattern matching / term rewriting (.cljc, ~5000 LOC)

### Results

| Metric      | Value |
|-------------|------:|
| Modules     | 18    |
| Load OK     |     6 |
| Load FAIL   |    12 |
| Load rate   | 33.3% |

### Module Loading Status

| Module                     | Status | Reason                              |
|----------------------------|--------|-------------------------------------|
| environment.epsilon        | OK     |                                     |
| protocols.epsilon          | OK     |                                     |
| util.epsilon               | FAIL   | Macro expansion failure (cascading) |
| syntax.epsilon             | FAIL   | Depends on util.epsilon             |
| match.syntax.epsilon       | FAIL   | `case*` map key integer issue (F139)|
| substitute.syntax.epsilon  | FAIL   | `&form` not available               |
| pattern-factory.epsilon    | FAIL   | `&form` not available               |
| matrix.epsilon             | OK     |                                     |
| match.ir.epsilon           | FAIL   | `&form` not available               |
| match.runtime.epsilon      | FAIL   | `&form` not available               |
| match.check.epsilon        | OK     |                                     |
| substitute.runtime.epsilon | FAIL   | `&form` not available               |
| substitute.epsilon         | FAIL   | `&form` not available               |
| strategy.epsilon           | FAIL   | `&form` not available               |
| interpreter.epsilon        | OK     |                                     |
| match.epsilon              | FAIL   | Macro expansion failure (cascading) |
| rewrite.epsilon            | OK     |                                     |
| meander.epsilon            | FAIL   | Macro expansion failure (cascading) |

### Primary Blockers

1. **`&form` implicit macro binding**: Many meander macros reference `&form` (the
   original form passed to the macro). CW does not provide this implicit binding.
2. **`case*` F139**: `case` macro with non-integer keys fails (known issue).
3. **util.epsilon macro expansion**: Root cause unknown — the function `set-k-permutations-with-unselected`
   fails to macroexpand when loaded via `load-string` in the meander namespace context.

### Bugs Fixed During Testing

| Bug | Fix |
|-----|-----|
| `ns` with `^:no-doc` metadata + docstring | with-meta unwrap in `setNsDocFn` |

### Notes

- No deftype/definterface used — all blockers are macro system gaps
- No Java interop beyond `cljs.tagged_literals.JSValue` import (benign)
- Implementing `&form` would unblock most modules (7/12 failures)

---

## core.match

Source: https://github.com/clojure/core.match
Type: Pattern matching (.clj, ~2000 LOC)
Status: **Out of scope** — heavy deftype, definterface, and clojure.lang internals
(Compiler/LOOP_LOCALS, clojure.lang.ILookup/IPersistentVector/ISeq protocol extensions)

---

## Libraries Tested But Not Yet Loadable

### clojure.data.json

Source: https://github.com/clojure/data.json
Category: **Blocked by definterface/deftype**
Blocker: `definterface` (JSONWriter), `deftype` with mutable fields
Notes: PushbackReader/StringWriter shims now available (75.D), but library requires
`definterface` which CW does not implement. `definterface` is simpler than `deftype`
and could potentially be added in a future phase.
