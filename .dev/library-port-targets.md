# Library Port Targets (Top 20)

CW compatibility testing targets. Pure or mostly-pure Clojure libraries.
Java interop in these is handled case-by-case (small shim vs skip vs library fork).

## Philosophy

CW is NOT a JVM reimplementation. We do NOT chase Babashka-level Java class coverage.
Instead: test real libraries, add minimal shims for high-frequency Java patterns,
and fork/adapt libraries when their Java deps are unnecessary.

See `babashka-class-compat.md` for reference only (not a roadmap).

## Status Legend

- **Pass**: All/most tests pass on CW
- **Partial**: Loads, some tests fail (documented)
- **Blocked**: Needs CW features not yet implemented
- **Todo**: Not yet tested

You should clone repo to ~/Documents/OSS if not exists.

## Batch 1: Already Planned (Phase 71)

| # | Library           | Repo                          | LOC   | Java Deps           | Status | Notes                       |
|---|-------------------|-------------------------------|-------|---------------------|--------|-----------------------------|
| 1 | medley            | weavejester/medley            | ~400  | None                | Tested | Utility fns, pure Clojure   |
| 2 | hiccup            | weavejester/hiccup            | ~300  | URI                 | Tested | HTML gen, URI needed → done |
| 3 | clojure.data.json | clojure/data.json             | ~500  | StringReader/Writer | Pass   | CW fork, 51 tests 80 asserts |
| 4 | honeysql          | seancorfield/honeysql         | ~2000 | None (spec)         | Tested | SQL DSL, spec.alpha dep     |
| 5 | camel-snake-kebab | clj-commons/camel-snake-kebab | ~200  | None                | Todo   | String case conversion      |

## Batch 2: Data & Transformation

| #  | Library          | Repo                  | LOC   | Java Deps     | Status | Notes                           |
|----|------------------|-----------------------|-------|---------------|--------|---------------------------------|
| 6  | clojure.data.csv | clojure/data.csv      | ~100  | Reader/Writer | Pass   | CW fork, 36 tests 36 asserts   |
| 7  | clojure.data.xml | clojure/data.xml      | ~800  | InputStream   | Todo   | XML, heavier I/O needs          |
| 8  | instaparse       | Engelberg/instaparse  | ~3000 | None          | Todo   | Parser combinator, pure Clojure |
| 9  | meander          | noprompt/meander      | ~5000 | None          | Todo   | Pattern matching, pure Clojure  |
| 10 | specter          | redplanetlabs/specter | ~2500 | None          | Todo   | Data navigation, pure Clojure   |

## Batch 3: Validation & Schema

| #  | Library            | Repo               | LOC   | Java Deps | Status | Notes                       |
|----|--------------------|--------------------|-------|-----------|--------|-----------------------------|
| 11 | malli              | metosin/malli      | ~8000 | Minimal   | Todo   | Data schemas, bb-compatible |
| 12 | clojure.core.match | clojure/core.match | ~1500 | None      | Todo   | Pattern matching, contrib   |

## Batch 4: Web & HTTP (lightweight)

| #  | Library           | Repo                 | LOC   | Java Deps  | Status  | Notes                                              |
|----|-------------------|----------------------|-------|------------|---------|----------------------------------------------------|
| 13 | ring-core (codec) | ring-clojure/ring    | ~200  | URLEncoder | Todo    | URL encoding only, not server                      |
| 14 | clj-yaml          | clj-commons/clj-yaml | ~300  | SnakeYAML  | Blocked | Needs Java YAML parser → skip or write pure parser |
| 15 | selmer            | yogthos/selmer       | ~2000 | Minimal    | Todo    | Templating, mostly pure                            |

## Batch 5: Utility & Testing

| #  | Library           | Repo              | LOC   | Java Deps      | Status | Notes                          |
|----|-------------------|-------------------|-------|----------------|--------|--------------------------------|
| 16 | clojure.tools.cli | clojure/tools.cli | ~400  | None           | Todo   | CLI arg parsing, pure Clojure  |
| 17 | clojure.walk      | (core)            | ~100  | None           | Pass   | Already in CW core             |
| 18 | clojure.set       | (core)            | ~200  | None           | Pass   | Already in CW core             |
| 19 | clojure.edn       | (core)            | ~100  | PushbackReader | Todo   | EDN reading, may need I/O shim |
| 20 | clojure.pprint    | (core)            | ~1500 | Writer         | Pass   | Already in CW (pprint.zig)     |

## Java Shim Decision Guide

When a library needs Java interop, decide:

1. **Frequency**: Is this pattern used by 3+ libraries? → Add shim
2. **Complexity**: Can we implement in <100 lines of Zig? → Add shim
3. **Alternative**: Is there a pure Clojure alternative? → Use that
4. **Fork**: Is the library worth forking to remove Java deps? → Fork

### Likely Shims Needed (from library analysis)

| Java Class               | Libraries      | Decision                                |
|--------------------------|----------------|-----------------------------------------|
| StringReader/Writer      | data.json, edn | **Add** — tiny, high frequency          |
| URLEncoder/Decoder       | ring, web libs | **Add** — small, many libs need it      |
| Base64                   | auth libs      | **Add** — std.base64 trivial            |
| PushbackReader           | clojure.edn    | **Add** — read already needs this       |
| StringBuilder            | various        | **Consider** — mutable str buffer       |
| InputStream/OutputStream | data.xml       | **Defer** — heavy, fork library instead |

## Tracking

Test results go in `.dev/compat-results.md` (create when first library tested).
Each entry: library name, CW version, pass/fail count, blockers, shims added.
