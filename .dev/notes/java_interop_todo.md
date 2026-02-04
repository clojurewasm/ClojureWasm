# ClojureWasm Java Interop Implementation List

Organized based on discussion. Includes both done and todo items.

---

## Priority 1: Beta-proven, High Value

### Hierarchy System

| Var              | Status | Note                      |
| ---------------- | ------ | ------------------------- |
| `make-hierarchy` | todo   | Zig builtin               |
| `derive`         | todo   | Zig builtin               |
| `underive`       | todo   | Zig builtin               |
| `parents`        | todo   | Zig builtin               |
| `ancestors`      | todo   | Zig builtin               |
| `descendants`    | todo   | Zig builtin               |
| `isa?`           | done   | → upgrade to full version |

### Multimethods

| Var                  | Status | Note             |
| -------------------- | ------ | ---------------- |
| `defmulti`           | done   | TreeWalk impl    |
| `defmethod`          | done   | TreeWalk impl    |
| `get-method`         | todo   | Zig builtin      |
| `methods`            | todo   | Zig builtin      |
| `remove-method`      | todo   | Zig builtin      |
| `remove-all-methods` | todo   | Zig builtin      |
| `prefer-method`      | todo   | Zig builtin      |
| `prefers`            | todo   | Zig builtin      |
| `dispatch-fn`        | todo   | not in vars.yaml |
| `hierarchy`          | todo   | not in vars.yaml |

### Protocols

| Var               | Status | Note                             |
| ----------------- | ------ | -------------------------------- |
| `defprotocol`     | done   | analyzer special form            |
| `extend-type`     | done   | analyzer special form            |
| `extend`          | todo   | primitive version of extend-type |
| `extend-protocol` | todo   | core.clj macro                   |
| `extenders`       | todo   | list of types implementing proto |
| `extends?`        | todo   | check if type implements proto   |
| `satisfies?`      | done   | Zig builtin                      |

### Exception Handling

| Var              | Status | Note         |
| ---------------- | ------ | ------------ |
| `try`            | done   | special form |
| `catch`          | done   | special form |
| `throw`          | done   | special form |
| `ex-info`        | done   | Zig builtin  |
| `ex-message`     | done   | Zig builtin  |
| `ex-data`        | done   | Zig builtin  |
| `ex-cause`       | todo   | Zig builtin  |
| `Throwable->map` | todo   | Zig builtin  |

### Types & Metadata

| Var           | Status  | Note                         |
| ------------- | ------- | ---------------------------- |
| `type`        | done    | Zig builtin                  |
| `class`       | done    | Zig builtin                  |
| `instance?`   | done    | core.clj                     |
| `with-meta`   | done    | Zig builtin                  |
| `alter-meta!` | done    | Zig builtin                  |
| `defrecord`   | done    | generates ->Name constructor |
| `deftype`     | partial | simplified map-based version |
| `record?`     | todo    | always false (no true types) |

---

## Priority 2: System/Math Analyzer Rewrite

### System/ Methods

| Java Syntax                  | Internal Function         | Status | Note                        |
| ---------------------------- | ------------------------- | ------ | --------------------------- |
| `(System/nanoTime)`          | `(__nano-time)`           | todo   | Zig std.time.nanoTimestamp  |
| `(System/currentTimeMillis)` | `(__current-time-millis)` | todo   | Zig std.time.milliTimestamp |
| `(System/getenv k)`          | `(__getenv k)`            | todo   | Zig std.process.getEnvMap   |
| `(System/exit n)`            | `(__exit n)`              | todo   | Zig std.process.exit        |

### Math/ Methods

| Java Syntax      | Internal Function | Status | Note             |
| ---------------- | ----------------- | ------ | ---------------- |
| `(Math/abs x)`   | `(abs x)`         | done   | Zig builtin      |
| `(Math/ceil x)`  | `(__ceil x)`      | todo   | Zig @ceil        |
| `(Math/floor x)` | `(__floor x)`     | todo   | Zig @floor       |
| `(Math/round x)` | `(__round x)`     | todo   | Zig @round       |
| `(Math/sqrt x)`  | `(__sqrt x)`      | todo   | Zig @sqrt        |
| `(Math/pow x y)` | `(__pow x y)`     | todo   | Zig std.math.pow |
| `(Math/sin x)`   | `(__sin x)`       | todo   | Zig @sin         |
| `(Math/cos x)`   | `(__cos x)`       | todo   | Zig @cos         |
| `(Math/tan x)`   | `(__tan x)`       | todo   | Zig @tan         |
| `(Math/log x)`   | `(__log x)`       | todo   | Zig @log         |
| `(Math/exp x)`   | `(__exp x)`       | todo   | Zig @exp         |
| `Math/PI`        | constant          | todo   | 3.14159...       |
| `Math/E`         | constant          | todo   | 2.71828...       |
| `(Math/random)`  | `(rand)`          | done   | Zig builtin      |

---

## Priority 3: UUID & Time

| Var           | Status | Note                   |
| ------------- | ------ | ---------------------- |
| `random-uuid` | todo   | Zig random + format    |
| `parse-uuid`  | todo   | parse UUID string      |
| `time`        | todo   | macro (show elapsed)   |
| `inst?`       | todo   | instant predicate      |
| `inst-ms`     | todo   | instant → milliseconds |

---

## Priority 4: IO Operations

### File IO

| Var           | Status | Note                         |
| ------------- | ------ | ---------------------------- |
| `slurp`       | done   | Zig fs.readToEndAlloc        |
| `spit`        | done   | Zig fs.createFile + writeAll |
| `line-seq`    | todo   | lazy line reader (Beta stub) |
| `file-seq`    | todo   | directory traversal          |
| `load-file`   | todo   | load and eval Clojure file   |
| `delete-file` | todo   | Zig fs.deleteFile            |
| `*file*`      | todo   | currently loading file       |

### Standard IO

| Var         | Status | Note            |
| ----------- | ------ | --------------- |
| `println`   | done   | Zig builtin     |
| `print`     | done   | Zig builtin     |
| `pr`        | done   | Zig builtin     |
| `prn`       | done   | Zig builtin     |
| `printf`    | todo   | formatted print |
| `newline`   | done   | Zig builtin     |
| `read-line` | todo   | read from stdin |
| `flush`     | done   | Zig builtin     |

### Dynamic Output

| Var            | Status | Note                 |
| -------------- | ------ | -------------------- |
| `*in*`         | todo   | stdin (dynamic var)  |
| `*out*`        | todo   | stdout (dynamic var) |
| `*err*`        | todo   | stderr (dynamic var) |
| `with-out-str` | todo   | capture output macro |
| `with-open`    | todo   | resource management  |

### String IO

| Var           | Status | Note        |
| ------------- | ------ | ----------- |
| `pr-str`      | done   | Zig builtin |
| `prn-str`     | done   | Zig builtin |
| `print-str`   | done   | Zig builtin |
| `println-str` | done   | Zig builtin |

### clojure.java.io Equivalent

| Var                   | Status | Note                      |
| --------------------- | ------ | ------------------------- |
| `io/reader`           | todo   | file → read handle        |
| `io/writer`           | todo   | file → write handle       |
| `io/input-stream`     | todo   | binary input stream       |
| `io/output-stream`    | todo   | binary output stream      |
| `io/copy`             | todo   | copy input → output       |
| `io/file`             | todo   | path → File-like object   |
| `io/make-parents`     | todo   | create parent directories |
| `io/resource`         | todo   | resolve resource path     |
| `io/as-relative-path` | todo   | convert to relative path  |

---

## Priority 5: Type Conversion

| Var      | Status | Note                     |
| -------- | ------ | ------------------------ |
| `int`    | todo   | integer conversion       |
| `long`   | todo   | = int (in ClojureWasm)   |
| `float`  | todo   | float conversion         |
| `double` | todo   | = float (in ClojureWasm) |
| `char`   | todo   | character conversion     |
| `num`    | todo   | numeric identity         |

---

## Priority 6: Single-threaded Simplified

| Var       | Status | Note                              |
| --------- | ------ | --------------------------------- |
| `future`  | todo   | eager eval version (like delay)   |
| `promise` | todo   | single-assignment value           |
| `deliver` | todo   | set promise value                 |
| `ref`     | todo   | single-threaded: atom-like        |
| `dosync`  | todo   | single-threaded: empty macro      |
| `alter`   | todo   | update ref                        |
| `commute` | todo   | update ref (= alter in single-th) |
| `ensure`  | todo   | single-threaded: no-op            |
| `atom`    | done   | Zig builtin                       |
| `deref`   | done   | Zig builtin                       |
| `reset!`  | done   | Zig builtin                       |
| `swap!`   | done   | Zig builtin                       |

---

## Priority 7: Bit Operations

| Var                        | Status | Note   |
| -------------------------- | ------ | ------ |
| `bit-and`                  | done   | Zig    |
| `bit-or`                   | done   | Zig    |
| `bit-xor`                  | done   | Zig    |
| `bit-not`                  | done   | Zig    |
| `bit-shift-left`           | done   | Zig    |
| `bit-shift-right`          | done   | Zig    |
| `bit-and-not`              | todo   | a & ~b |
| `bit-clear`                | todo   |        |
| `bit-flip`                 | todo   |        |
| `bit-set`                  | todo   |        |
| `bit-test`                 | todo   |        |
| `unsigned-bit-shift-right` | todo   | >>>    |

---

## Priority 8: Require/Namespace

| Var       | Status | Note                        |
| --------- | ------ | --------------------------- |
| `ns`      | done   | :require/:use support added |
| `in-ns`   | done   | Zig builtin                 |
| `require` | done   | Zig builtin (no file load)  |
| `use`     | done   | Zig builtin (no file load)  |
| `refer`   | done   | Zig builtin                 |
| `alias`   | done   | Zig builtin                 |

---

## Deferred: Future Phases

| Var      | Note                                           |
| -------- | ---------------------------------------------- |
| `bigint` | arbitrary precision int (Reader + Value + ops) |
| `bigdec` | arbitrary precision decimal (same)             |
| `ratio`  | ratio type (F3)                                |

---

## Skip: Will Not Implement

- `Boolean/TRUE`, `Boolean/FALSE` — `true`/`false` suffice
- `clojure.lang.MapEntry.` — use `(vector k v)` instead
- `.getMessage`, `.getCause` — use `ex-message`, `ex-cause`
- `reify`, `proxy`, `gen-class`, `gen-interface` — JVM required
- `definterface`, `init-proxy`, `proxy-super`, `proxy-mappings` — proxy-dependent
- `lock`, `unlock` — non-standard / JVM-dependent

---

## Summary

| Priority  | Todo   | Done   | Category                    |
| --------- | ------ | ------ | --------------------------- |
| P1        | 15     | 20     | Hierarchy, Multi, Proto     |
| P2        | 15     | 2      | System/Math rewrite         |
| P3        | 5      | 0      | UUID & Time                 |
| P4        | 32     | 1      | IO operations               |
| P5        | 6      | 0      | Type conversion             |
| P6        | 8      | 4      | Single-threaded concurrency |
| P7        | 6      | 6      | Bit operations              |
| P8        | 4      | 2      | Require/Namespace           |
| P9        | 0      | 8      | Control structures (ref)    |
| **Total** | **91** | **43** |                             |
