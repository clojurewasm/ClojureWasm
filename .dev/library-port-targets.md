# Library Compatibility Testing Targets

## Purpose

Test real-world Clojure libraries **as-is** on CW. Libraries are NOT forked or
embedded — they are loaded from their original source, and their original test
suites are run unmodified. CW itself gets fixed to pass the tests.

Goals:
1. **Behavioral equivalence**: Find where CW differs from upstream Clojure, then
   trace CW's processing pipeline (reader → analyzer → compiler → VM/TreeWalk →
   builtins) to find and fix the root cause. Library tests serve as a specification
   of correct Clojure behavior.
2. **Bug discovery**: Find CW implementation bugs surfaced by real-world usage patterns
3. **Missing feature discovery**: Identify unimplemented features needed by libraries
4. **Java interop gap analysis**: Determine which Java classes/methods need Zig equivalents

## Java Interop Decision

CW is NOT a JVM reimplementation. When a library needs Java interop:
- **High frequency** (3+ libraries need it) AND **small** (<100 lines Zig) → Add Zig interop shim
- **Otherwise** → That library is **out of scope** for CW. Document the gap and move on.
  Do NOT fork the library. Do NOT embed modified copies. Accept the limitation.

## Status Legend

- **Pass**: All/most tests pass on CW as-is
- **Partial**: Loads, some tests fail (documented in RESULTS.md)
- **Load**: Namespace loads but tests not yet run
- **Blocked**: Needs CW features not yet implemented
- **Todo**: Not yet tested

You should clone repo to ~/Documents/OSS if not exists.

## Batch 1: Already Tested (Phase 71-72)

| # | Library           | Repo                          | LOC   | Java Deps           | Status  | Notes                       |
|---|-------------------|-------------------------------|-------|---------------------|---------|-----------------------------|
| 1 | medley            | weavejester/medley            | ~400  | None                | Partial | 80.4% — Java interop = all failures |
| 2 | hiccup            | weavejester/hiccup            | ~300  | URI                 | Skipped | Heavy Java interop          |
| 3 | honeysql          | seancorfield/honeysql         | ~2000 | None (spec)         | Load    | All 3 ns load OK            |
| 4 | camel-snake-kebab | clj-commons/camel-snake-kebab | ~200  | None                | Partial | 98.6% — split edge case     |

## Batch 2: Data & Transformation

| #  | Library          | Repo                  | LOC   | Java Deps     | Status  | Notes                                    |
|----|------------------|-----------------------|-------|---------------|---------|------------------------------------------|
| 5  | clojure.data.json| clojure/data.json     | ~500  | PushbackReader, StringWriter | Blocked | Needs Java I/O shims |
| 6  | clojure.data.csv | clojure/data.csv      | ~100  | PushbackReader, Writer | Blocked | Same shims as data.json |
| 7  | clojure.data.xml | clojure/data.xml      | ~800  | InputStream   | Todo    | XML, heavier I/O needs     |
| 8  | instaparse       | Engelberg/instaparse  | ~3000 | None          | Todo    | Parser combinator, pure Clojure |
| 9  | meander          | noprompt/meander      | ~5000 | None          | Todo    | Pattern matching, pure Clojure |
| 10 | specter          | redplanetlabs/specter | ~2500 | None          | Todo    | Data navigation, pure Clojure |

## Batch 3: Validation & Schema

| #  | Library            | Repo               | LOC   | Java Deps | Status | Notes                       |
|----|--------------------|--------------------|-------|-----------|--------|-----------------------------|
| 11 | malli              | metosin/malli      | ~8000 | Minimal   | Todo   | Data schemas, bb-compatible |
| 12 | clojure.core.match | clojure/core.match | ~1500 | None      | Todo   | Pattern matching, contrib   |

## Batch 4: Web & HTTP (lightweight)

| #  | Library           | Repo                 | LOC   | Java Deps  | Status  | Notes                                              |
|----|-------------------|----------------------|-------|------------|---------|----------------------------------------------------|
| 13 | ring-core (codec) | ring-clojure/ring    | ~200  | URLEncoder | Todo    | URL encoding only, not server                      |
| 14 | clj-yaml          | clj-commons/clj-yaml | ~300  | SnakeYAML  | Blocked | Needs Java YAML parser                             |
| 15 | selmer            | yogthos/selmer       | ~2000 | Minimal    | Todo    | Templating, mostly pure                            |

## Batch 5: Utility & Testing

| #  | Library           | Repo              | LOC   | Java Deps      | Status  | Notes                                |
|----|-------------------|-------------------|-------|----------------|---------|--------------------------------------|
| 16 | clojure.tools.cli | clojure/tools.cli | ~400  | None           | Blocked | Regex backtracking, catch body       |
| 17 | clojure.walk      | (core)            | ~100  | None           | Pass    | Already in CW core                   |
| 18 | clojure.set       | (core)            | ~200  | None           | Pass    | Already in CW core                   |
| 19 | clojure.edn       | (core)            | ~100  | PushbackReader | Todo    | EDN reading, may need I/O shim       |
| 20 | clojure.pprint    | (core)            | ~1500 | Writer         | Pass    | Already in CW (pprint.zig)           |

## Java Interop Shim Decision Guide

When a library fails due to Java interop:

1. **Frequency**: Is this pattern used by 3+ libraries? AND **Complexity**: <100 lines Zig? → Add Zig shim
2. **Alternative**: Is there a pure Clojure equivalent CW already supports? → Use that
3. **Otherwise**: That library is **out of scope**. Record the blocker in RESULTS.md and move on. Do NOT fork the library to work around it.

### Likely Shims Needed (from library analysis)

| Java Class               | Libraries      | Decision                                |
|--------------------------|----------------|-----------------------------------------|
| PushbackReader           | data.json, data.csv, edn | **High** — needed for I/O-based libs |
| StringWriter/StringBuilder | data.json, data.csv | **High** — output buffering       |
| URLEncoder/Decoder       | ring, web libs | **Medium** — small, many libs need it   |
| Base64                   | auth libs      | **Medium** — std.base64 trivial         |
| java.util.ArrayList      | medley         | **Low** — only medley partition-* uses it |
| InputStream/OutputStream | data.xml       | **Defer** — heavy, fork library instead |

## Tracking

Detailed test results: `test/compat/RESULTS.md`
