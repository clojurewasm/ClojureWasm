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

## Embed vs External Rule

本家 `clojure.jar` に同梱されている namespace = CW に embed (`@embedFile` or Zig builtin)。
別 Maven artifact (`org.clojure/data.json` 等) = 外部ライブラリ（deps.edn 経由でロード）。

## Target Libraries

Clone repos to ~/Documents/OSS if not exists.
Results and status tracking: `test/compat/RESULTS.md` (single source of truth).

### Batch 0: Missing clojure.jar Namespaces

clojure.jar 同梱だが CW 未実装の namespace。embed 対象（CLJW markers OK）。
Detail: `.dev/missing-clj-namespaces.md`

| #  | namespace             | LOC  | Difficulty | Notes                             |
|----|-----------------------|------|------------|-----------------------------------|
| 0a | clojure.uuid          | ~20  | Small      | Verify UUID coverage              |
| 0b | clojure.test.tap      | ~123 | Small      | TAP output, nearly pure Clojure   |
| 0c | clojure.java.browse   | ~89  | Small      | browse-url via shell              |
| 0d | clojure.datafy        | ~62  | Small      | datafy/nav protocols              |
| 0e | clojure.instant       | ~294 | Medium     | #inst reader + Zig date type      |
| 0f | clojure.java.process  | ~196 | Medium     | Process API, Zig std.process      |
| 0g | clojure.main          | ~676 | Large      | CW-native main ns                 |
| 0h | clojure.core.server   | ~341 | Large      | Socket REPL + prepl               |
| 0i | clojure.repl.deps     | ~97  | Large      | CW-native REPL deps               |

Skip: clojure.reflect, clojure.inspector, clojure.java.javadoc, clojure.test.junit.
Defer: clojure.xml (implement if library testing surfaces demand).

### Batch 1: Utility & Case

| # | Library           | Repo                          | LOC   | Java Deps           |
|---|-------------------|-------------------------------|-------|---------------------|
| 1 | medley            | weavejester/medley            | ~400  | None                |
| 2 | hiccup            | weavejester/hiccup            | ~300  | URI                 |
| 3 | honeysql          | seancorfield/honeysql         | ~2000 | None (spec)         |
| 4 | camel-snake-kebab | clj-commons/camel-snake-kebab | ~200  | None                |

### Batch 2: Data & Transformation

| #  | Library          | Repo                  | LOC   | Java Deps                      |
|----|------------------|-----------------------|-------|--------------------------------|
| 5  | clojure.data.json| clojure/data.json     | ~500  | PushbackReader, StringWriter   |
| 6  | clojure.data.csv | clojure/data.csv      | ~100  | PushbackReader, Writer         |
| 7  | clojure.data.xml | clojure/data.xml      | ~800  | InputStream                    |
| 8  | instaparse       | Engelberg/instaparse  | ~3000 | None                           |
| 9  | meander          | noprompt/meander      | ~5000 | None                           |
| 10 | specter          | redplanetlabs/specter | ~2500 | None                           |

### Batch 3: Validation & Schema

| #  | Library            | Repo               | LOC   | Java Deps |
|----|--------------------|--------------------|-------|-----------|
| 11 | malli              | metosin/malli      | ~8000 | Minimal   |
| 12 | clojure.core.match | clojure/core.match | ~1500 | None      |

### Batch 4: Web & HTTP (lightweight)

| #  | Library           | Repo                 | LOC   | Java Deps  |
|----|-------------------|----------------------|-------|------------|
| 13 | ring-core (codec) | ring-clojure/ring    | ~200  | URLEncoder |
| 14 | clj-yaml          | clj-commons/clj-yaml | ~300  | SnakeYAML  |
| 15 | selmer            | yogthos/selmer       | ~2000 | Minimal    |

### Batch 5: Utility & Testing

| #  | Library           | Repo              | LOC   | Java Deps      |
|----|-------------------|-------------------|-------|----------------|
| 16 | clojure.tools.cli | clojure/tools.cli | ~400  | None           |
| 17 | clojure.walk      | (core)            | ~100  | None           |
| 18 | clojure.set       | (core)            | ~200  | None           |
| 19 | clojure.edn       | (core)            | ~100  | PushbackReader |
| 20 | clojure.pprint    | (core)            | ~1500 | Writer         |

## Java Interop Shim Decision Guide

When a library fails due to Java interop:

1. **Frequency**: Is this pattern used by 3+ libraries? AND **Complexity**: <100 lines Zig? → Add Zig shim
2. **Alternative**: Is there a pure Clojure equivalent CW already supports? → Use that
3. **Otherwise**: That library is **out of scope**. Record the blocker in RESULTS.md and move on. Do NOT fork the library to work around it.

### Likely Shims Needed (from library analysis)

| Java Class               | Libraries                 | Priority                          |
|--------------------------|---------------------------|-----------------------------------|
| PushbackReader           | data.json, data.csv, edn | **High** — needed for I/O-based libs |
| StringWriter/StringBuilder | data.json, data.csv     | **High** — output buffering       |
| URLEncoder/Decoder       | ring, web libs            | **Medium** — small, many libs need it |
| Base64                   | auth libs                 | **Medium** — std.base64 trivial   |
| java.util.ArrayList      | medley                    | **Low** — only medley partition-* |
| InputStream/OutputStream | data.xml                  | **Defer** — heavy                 |
