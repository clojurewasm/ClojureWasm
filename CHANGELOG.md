# Changelog

All notable changes to ClojureWasm are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/). SemVer compatibility guarantees start at the
first stable `1.0.0` tag; pre-1.0 `alpha` / `rc` tags may still change surfaces.

## [Unreleased]

### Changed

- Transient maps and sets now edit owned HAMT paths in place during `into`,
  cloning only shared nodes; `persistent!` freezes ownership so later transients
  cannot mutate published maps. The `into_collections` workload drops from
  18.215B to 17.111B user instructions (-6.1%); isolated 20k-entry map `into`
  drops from 2.599B to 2.016B (-22.4%) on one pinned core.

### Fixed

- The non-blocking bench-vs-bb CI job no longer fails on a restored
  `.zig-cache` whose WriteFiles output is missing (`file_hash FileNotFound`
  on `bootstrap_sources_stub.zig`). The job only reads the cache, so on a
  failed build it drops `.zig-cache` and builds cold once.

### Changed

- Allocating a small GC cell is cheaper: the page heap's free-slot and bump
  path is now inlined into each typed allocation site, with the size class
  and the small/large choice folded at compile time, and the live-list
  record is stored in place when the list has room. On a pinned core (user
  instructions): lazy_chain 9.07 G to 8.27 G (-8.8 %), gc_churn 8.05 G to
  7.75 G (-3.7 %), about 85 fewer instructions per allocation. Peak RSS is
  unchanged.
- `(inc x)` and `(dec x)` on canonical `clojure.core/inc`/`dec` now compile to
  VM intrinsics (`op_inc` / `op_dec`) instead of a generic call into the
  builtin. Fixnums and floats are computed inline; any other operand, an i48
  overflow and a redefined `inc`/`dec` (`alter-var-root`) still go through the
  builtin. The VM no longer runs a per-op cold-opcode test or publishes the
  handler top on every op, and the arith fast path is inlined. The empty
  `(loop [i 0 s 0] (if (< i n) (recur (inc i) (+ s 1)) s))` costs about 833
  user instructions per iteration, down from 1585 (pinned core,
  `instructions:u`); `(loop [i 0] (if (< i n) (recur (inc i)) i))` 601, down
  from 1307. Bytecode format v15 (v14 artifacts are rejected).
- A string of up to about 4 KB now keeps its bytes inside its own GC cell
  instead of in a separate malloc block freed by a finaliser: one allocation
  per string instead of two. Measured on a pinned core (user instructions, a
  noisy host made wall time unreliable): `(count (str i))` in a loop costs 2300
  instructions per iteration over the empty loop, down from 2790; bench/vs_bb
  string_ops 5959M -> 5219M (-12%), gc_churn 8369M -> 8011M (-4%). Wall time
  at load ~40: string_ops 2.02x -> 1.49x bb, probe str_ms 321-439 -> 245-439
  ms (bb 71-122).

- A small vector's tail and an array map's entries are now sized to their
  element count inside one GC cell, not a fixed 32-slot tail (272 bytes) and
  a fixed 16-slot entry array (152 bytes). 200k retained `{:id i :v [i (inc i)]}`
  hold 29.6 MB live instead of 97.2 MB (148 bytes per entry, was 486), and
  `bench/vs_bb/workloads/gc_churn.clj` allocates 175 MB instead of 497 MB.

- **Double arithmetic and comparison stay inline in the VM (O-065).** A double
  paired with a double or a long computes `+ - * < <= > >=` in f64 without the
  builtin var call. Instruction counts: dot product over 1k doubles -12%,
  over 100k -11%, a float `loop`/`recur` -26%.

- **Lazy `map`, `filter`, `take` and `iterate` realize their nodes natively
  (O-110).** A lazy chain no longer re-enters the evaluator per element to
  step a `lazy-seq` thunk. `bench/vs_bb` lazy_chain went from 13.75x bb to
  2.28x bb (1315 ms vs bb 576 ms in-process), with peak RSS 117 MB vs bb 198.

- **The collect trigger grows the heap by one live set, not two
  (CLJW-PERF-GC-RETAIN).** The threshold is now `max(floor, last_live)`
  instead of `max(floor, 2 * last_live)`; peak heap is about live plus one
  threshold, so a large live set no longer peaks near 3x itself. Peak RSS:
  1M retained maps plus churn 1729 MB to 1153 MB (-33%), `bench/vs_bb`
  gc_churn 352 MB to 242 MB (-31%), for +1.8% instructions on gc_churn and
  +4.5% on the large-live probe; a small-live high-churn loop is unchanged.

## [1.15.4] - 2026-10-23

### Added

- **`java.time.format`: `DateTimeFormatter`, `DateTimeFormatterBuilder`,
  `ChronoField`, `ZoneId` and `ZoneOffset`.** Pattern letters
  `G u y M L d D F E a h K k H m s S n A N V X x Z O`, optional sections,
  SMART and STRICT resolvers and the 12 `ISO_*` constants. Letters cljw does
  not implement raise `not_implemented` instead of formatting wrong text. This
  was the last blocker for `malli.transform`.
- **Primitive arrays cross `cljw.ffi` and wasm memory at memcpy speed
  (ADR-0204).** `byte`/`short`/`int`/`long`/`float`/`double`/`char`/`boolean`
  arrays hold raw native elements. A `:pointer` argument passes the array's
  storage with no copy, `:bytes` is one memcpy, `wasm/mem-write!` accepts a
  primitive array and the new `wasm/mem-read-array` returns one. `bytes?` is
  true only for a byte array.
- **`bench/vs_bb`:** 14 workloads that compare cljw with bb and JVM Clojure,
  with a non-blocking CI report.
- **`docs/examples/zig-native`:** one Zig source used both as a wasm guest and
  as a `cljw.ffi` library.

### Changed

- **Core sequence functions are much faster (ADR-0205).** The seq of a vector
  is now chunked by leaf, as clj's `PersistentVector$ChunkedSeq` is, and
  `map`, `filter`, `into`, `mapv` and `reduce` go through one chunked-seq
  boundary and the Zig `reduce`. On an 8000-element vector,
  `(reduce + (map inc v))` went from 19271 us to 718 us and
  `(count (filter even? v))` from 19646 us to 490 us. `(first (map f v))` now
  realizes 32 elements, as clj does.
- **Protocol calls hit a per-function dispatch cache (ADR-0206).** Each
  protocol function remembers the method it resolved for the last receiver
  type; every `extend`, `extend-type`, `extend-protocol` and type redefinition
  invalidates it.
- **A Clojure fn call no longer memsets its scratch buffers.** ReleaseSafe
  filled about 2 KB of locals with 0xAA on every call. Skipping it cuts 18%
  of instructions from `seq_dot`, 38% from `lazy_chain`, 35% from multimethod
  dispatch and 10% from startup.
- **String and vector hot paths:** `clojure.string/join`, `upper-case`,
  `lower-case` and `split`, `subvec`, `str`, keyword interning and
  `dorun`/`doall` take native fast paths. The `string_ops` bench went from
  9.3x bb to 2.3x bb.
- **Cold start does less work.** Deserializing the core image no longer maps
  a page per quoted list. `cljw -e nil` takes 27.3 ms of CPU, against 38.8 ms
  before and 29.1 ms for bb.
- **The GC returns freed memory and reuses it.** Small cells live in 64 KiB
  pages that are unmapped once empty, and String, array, transient-vector and
  BigInt payload bytes now count toward the collect trigger, so long-lived
  processes no longer hold their high-water mark.

### Fixed

- **`clojure.edn` reads the EDN dialect.** It used the permissive Clojure
  reader and accepted EDN-invalid input; it now matches JVM Clojure's
  `EdnReader` on 59 of 59 cases.
- **wasm `i64` arguments and results cross exactly over the full range.**
  Values past 2^47 came back as a lossy Double or were refused, and an
  integral float of 2^63 crashed the host.
- **A BigInt, Ratio or BigDecimal past about 1233 digits prints its digits.**
  It printed the literal `(BigInt)`.
- **A long-running server that reads stdin now gives memory back.** The
  `*in*` and `System/in` readers kept every byte they had ever read; they now
  drop what has been consumed. While the main thread waits on stdin, each idle
  second runs a collect (when at least 1 MiB was allocated since the last one)
  and returns freed memory to the OS, so garbage left by `future`s and worker
  threads no longer waits for the next request. Socket and `StringBuilder`
  buffers now count toward the collect trigger. A bb-mcp-shaped probe (20
  `future`s each building 4 MB of JSON, then idle) settles at 129 MB instead
  of holding 955 MB.

- **A `wasm/call` on the JIT no longer costs time proportional to the
  module.** zwasm resolved the export by re-parsing the module on every call;
  it now reads the export table built at compile. A trivial export of a 47 KB
  module went from about 5.9 us to 0.8 us a call, the same as a tiny module.
  `bench/wasm_percall.clj` gains `big-*` cells that measure it.
- **A wasm handle called from a `future` no longer traps on the interpreter.**
  zwasm's interpreter cached the first calling thread's native-stack limit on
  the instance, so a handle warmed on the runtime thread and then called from
  another thread whose stack lay below that limit trapped
  `CallStackExhausted`. The limit is now per calling thread (zwasm 79f3d63a).

## [1.15.3] - 2026-10-22

### Added

- **Release binaries carry signed build provenance and a `SHA256SUMS` file.**
  Each tarball gets a Sigstore attestation from the release workflow, so
  `gh attestation verify cljw-linux-x86_64.tar.gz -R BuddhiLW/ClojureWasm`
  proves it was built by that workflow from a given commit. `SHA256SUMS`
  collects the per-asset sums for `sha256sum -c`.

### Changed

- **`brew install clojurewasm/tap/cljw` is the advertised install.** Each
  repository's release now bumps its own owner's tap from its own build:
  BuddhiLW/ClojureWasm keeps `buddhilw/tap`, clojurewasm/ClojureWasm drives
  `clojurewasm/tap`. A fork without a `TAP_DEPLOY_KEY` skips the tap job.

## [1.15.2] - 2026-10-21

### Fixed

- **The release workflow bumps the Homebrew tap only from
  BuddhiLW/ClojureWasm.** An upstream mirror carrying the workflow cut its own
  build of v1.15.1 and tried to write that build's checksums into
  `Formula/cljw.rb`, whose urls name this repository's release assets. The push
  failed with a 403; had it succeeded, `brew install` would have rejected the
  download. The `tap` job is now skipped in any other repository.

## [1.15.1] - 2026-10-21

### Added

- **`wasm/exports` lists a core module's exports.** `(wasm/exports m)` returns
  a vector in export order: a function as `{:name "sum_f64" :kind :func
  :params [:i32 :i32] :results [:f64]}`, a memory, global or table as
  `{:name "memory" :kind :memory}`. Signatures come from the same runtime probe
  `wasm/call` uses (ADR-0203).

- **Dot interop on a Wasm module handle.** `(.sum_f64 m buf 4)`,
  `(. m sum_f64 buf 4)` and `(. m (sum_f64 buf 4))` call the export named by
  the method symbol, verbatim, through `wasm/call`'s own path, so results,
  fuel and errors are identical. A C function compiled to Wasm is called like a
  host method (ADR-0203).

### Changed

- **zwasm pinned to the fork's `main` (d74e63b4, upstream main of
  2026-10-21).** Upstream now carries the component re-export, wasip2
  `metadata-hash` and `PreparedWasi` fixes the fork's `cljw` branch existed
  for.

- **A shorter README** led by calling C from Clojure, with the architecture,
  size and startup charts kept.

### Fixed

- **Redefining a deftype or defrecord is safe, and a user class is matched by
  identity, not by name.** Re-registering a type no longer frees a descriptor
  live instances still use (the `thread panic: integer overflow` on printing
  an old instance is gone). `aaa.Point` and `bbb.Point` are two classes, and
  `instance?`, `.isInstance`, class `isa?` and multimethod dispatch agree with
  `(= (class x) C)` for a redefined record, a namesake in another namespace
  and a reify class. A bare `(Point. x y)` or `->Point` builds the class of the
  namespace the form was written in, even after another namespace registered a
  namesake of a different shape. Compiled chunks move to format v13.

- **The VM reports errors at their form.** `set!` on an unbound var, an
  unresolved or unsupported `.member` call, a static method call, a
  constructor arity failure, `import` and `require`/`refer` failures raised on
  the VM with no source position (`0:0`) while TreeWalk reported line and
  column. Both backends now report the same position, and the dual-backend
  test oracle checks it for every failing case.

## [1.15.0] - 2026-10-13

### Added

- **deps.edn Maven source JAR resolution.** `:mvn/version` loads `.clj`, `.cljc`
  and `.cljw` sources from `$M2_REPO` (`~/.m2/repository` by default), fetching
  absent artifacts from Clojars then Maven Central via HTTPS. Compile/runtime
  POM dependencies are traversed; JVM-only JARs and `org.clojure/clojure` do
  not enter the classpath. Source extraction is cached under `$CLJW_HOME/mvn`.
  Every remotely fetched JAR and POM requires a matching SHA-1 sidecar from
  the same repository before installation; a missing or mismatched checksum
  fails closed. `CLJW_MVN_REPOS` accepts comma-separated repository base URLs
  (default Clojars, Maven Central; `file://` supports hermetic fixtures).

- **`cljw.ffi`: call C symbols in a shared library.** `(ffi/open path)`,
  `(ffi/function lib "name" [:int :double] :long)` gives an ordinary Clojure
  fn, plus `close`, `sym`, `call`, `string` and `bytes`. Types `:void :int
  :long :double :pointer :string :bytes`; up to 6 integer-class and 8 double
  arguments, called through one register-only shape with no libffi
  (ADR-0202). Errors are `ex-info` with `{:ffi/error ...}`. The same API as
  clojurust's `clojure.rust.ffi`. On x86_64 / aarch64 Linux and macOS
  (`-Dffi=false` drops it); absent on wasm. Example:
  `docs/examples/ffi/hive_call.clj` drives the hive C ABI.

- **`java.lang.Number` instance methods on every number.** Long, Double,
  BigInt, Ratio and BigDecimal answer `.intValue`, `.longValue`,
  `.shortValue`, `.byteValue`, `.doubleValue` and `.floatValue`; Long, Double,
  BigInt and Ratio also answer the class-gated `.compareTo`, `.equals` and
  `.hashCode` with their JVM semantics (not clj `=` / `hash`), and a Double
  answers `.isNaN` and `.isInfinite`. Narrowing follows the JLS: an integer
  keeps its low bits, a Double truncates toward zero and saturates, NaN gives
  0. `.floatValue` answers the double, as `(float x)` does (AD-004).

- **Ratio literals wider than a Long.** `24691357802469135781/2` reads as a
  Ratio in source, `read-string` and `clojure.edn/read-string`, and a literal
  that divides evenly collapses to a Long or BigInt exactly as `/` does. Such
  ratios compare, `max`/`min` and truncate (`bigint`, `biginteger`) by exact
  value, never through doubles; `long` and `int` still reject one past their
  range.

- **`clojure.lang.RT/nextID`.** Returns the next value of the per-runtime
  gensym counter, so ids are monotonic and never collide with gensym
  suffixes. core.logic mints logic-variable ids with it.

- **`clojure.lang.IRecord` and `clojure.lang.Fn` as interfaces.** Every
  defrecord is an `(instance? clojure.lang.IRecord r)`, and `extend-type` /
  `extend-protocol` onto `IRecord` reaches every record (after the record's
  own impls, before an `Object` default). `clojure.lang.Fn` names fns,
  builtins and protocol fns, but not a MultiFn or an invocable keyword or
  collection, as in clj. `(. Class member)` and `(. Class (member args))` on
  a class symbol are static access, for fields as well as methods.

- **A `deftype` or `reify` can implement `java.util.Map$Entry`.** Declaring
  `java.util.Map$Entry` or `clojure.lang.IMapEntry` with `getKey` /
  `getValue` makes `key`, `val` and `map-entry?` answer the instance, and the
  methods stay dot-callable. core.logic's `Pair` loads.

### Changed

- **`cljw script.clj a b` passes `a b` to the script.** Every token after
  the script path is bound to `*command-line-args*`, as `clojure script.clj
  a b` does; cljw used to open `a` as another source file. A `-cp` /
  `--classpath <dirs>` directly after the script path is still the classpath
  option (`cljw app.clj -cp lib`); the first other token starts the script
  arguments, and everything from there on is an argument.

- **Large collection literals build at any size.** A vector, map or set
  literal of constants folds into one constant, and one with evaluated
  elements is built in bounded steps, so `[1 1 1 … 40000 elements]` no longer
  ends the process with an uncatchable operand stack overflow (D-346). Code
  past a compiler limit raises the catchable `form_too_large`, and a full
  operand arena the catchable `stack_overflow`. `cljw build` writes bytecode
  format v12.

- **Regex patterns take up to 1024 capturing groups** (was 7). The 8th group
  used to be reported as an unsupported feature; emmy.complex's number
  pattern has 8. More than 1024 raises a catchable "too many capturing
  groups" error, and a backreference is still unsupported but now named as
  such.

- **`wasm/run` compiles a module once and reuses it.** The first `(wasm/run
  path …)` validates and JIT-compiles the module; later runs of the same file
  only instantiate and run it, each with its own `:args`, `:stdin`, `:env`,
  `:dir`/`:dirs`, `:fuel`, `:max-memory-pages`, `:max-output-bytes` and
  `:timeout-ms`, and return the same `{:out :err :exit}`. A Go wasip1 guest
  that cost 1 to 2 s of CPU per call pays that once; later calls take 0.11 to
  0.27 s. Up to 8 modules stay
  compiled, keyed by the file's path, inode, size and mtime, so an edited
  file is compiled again. `{:cache false}` compiles for that call only, and
  `(wasm/clear-cache!)` drops every cached module and returns how many there
  were.

- **Strings indexed by code point are now a recorded divergence (AD-076).**
  Behaviour is unchanged: `count`, `subs`, `nth`, `seq` and the interop
  methods `.length`, `.charAt`, `.indexOf` and `.substring` count a character
  outside the BMP as one position, where clj counts its UTF-16 surrogate pair
  as two (`(count "🌍")` is 1 in cljw, 2 in clj). The rationale and porting
  guidance are in `docs/clojure_vs_clojurewasm.md`, and
  `test/clj/suites/string_code_point_test.clj` pins the answers (#1).

### Fixed

- **A number token runs to the next delimiter and is rejected whole, as in
  clj.** `(read-string "12x")`, `"1.5x"`, `"1/2x"`, `"1/2/3"` and `"4/-2"`
  raise NumberFormatException "Invalid number: 12x" (and so on) in source,
  `read-string` and `clojure.edn/read-string`, where cljw used to read the
  leading number and start a new token with the rest. `[1/2x]` in code is now
  a reader error, not an unresolved symbol `x`. `#`, `'` and `%` end a number
  token. `0xFFN` and `017N` read as BigInts, and `1.5N` is refused.

- **`compare`, `sort` and sorted collections order Date, UUID, File and
  Comparable deftypes.** `java.util.Date` orders by time, `java.util.UUID` as
  `UUID.compareTo` does (signed most-significant long, then least), a
  `java.io.File` by its path, and a `deftype` or `reify` implementing
  `java.lang.Comparable` through its `compareTo`, in `compare`, `sort`,
  `sort-by`, `sorted-set` and `sorted-map` alike. `compare` returns the
  receiver's compareTo int unchanged, so `(compare (java.io.File. "a")
  (java.io.File. "c"))` is -2, as in clj. Incomparable pairs, such as a Date
  and a UUID, still raise ClassCastException.

- **`find`, `select-keys` and a set's `get` answer the STORED key.** `(find
  {1N :a} 1)` is `[1N :a]`, `(find {0.0 :z} -0.0)` is `[0.0 :z]`,
  `(select-keys {1N :a} [1])` is `{1N :a}` and `(get #{1N} 1)` is `1N`, for
  array, hash and sorted maps and sets and transient sets, as in clj. A
  transient map's `find` keeps the probe key, as `ATransientMap.entryAt` does.

- **Ratio and BigDecimal convert to double as clj's `doubleValue`.** A Ratio
  rounds through a DECIMAL64 quotient and a BigDecimal rounds once to the
  nearest double, in `double`, float contagion, mixed comparison, `format`
  and `.doubleValue` alike: `(double 2/3)` is `0.6666666666666667`, `(double
  0.3M)` is `0.3` and `(== 2/3 0.6666666666666667)` is true, where cljw gave
  `0.6666666666666666`, `0.30000000000000004` and false. `(double 1e400M)` is
  `##Inf`, not NaN. `(/ Long/MIN_VALUE 1)` is a BigInt, as in clj.

- **`Long/valueOf` raises IllegalArgumentException on an unmatched
  overload.** A BigInt or a Double argument used to raise a type error no
  `catch IllegalArgumentException` caught; `nil` raises
  NumberFormatException, as in clj.

- **Equal Date and java.time values hash alike.** `Date`, `Timestamp`,
  `Instant`, `Duration`, `LocalDate`, `LocalDateTime` and `LocalTime` hash by
  their JDK `hashCode`, so `hash-set`, map lookup, `distinct`, `frequencies`
  and `group-by` no longer split equal instances. `compare` orders two
  `java.sql.Timestamp`s (millis, then nanos); a Timestamp against a Date still
  raises.

- **Collection predicates answer a `deftype` or `reify` from its declared
  interfaces.** `seq?`, `coll?`, `counted?`, `sequential?`, `associative?`,
  `vector?`, `map?`, `set?`, `sorted?`, `ifn?`, `indexed?`, `reversible?` and
  `seqable?` follow the type's interfaces and clj's superinterface closure.
  A map entry and the three transients are `ifn?`, as in clj.

- **clojure.string and the regex fns accept any CharSequence.** `trim`,
  `blank?`, `split`, `split-lines`, `escape`, `reverse`, `re-find`,
  `re-matches`, `re-seq` and the rest read a `StringBuilder` or a
  CharSequence `deftype` as its text, and `seq`, `count` and `nth` treat a
  `StringBuilder` as a CharSequence. A non-CharSequence is still refused.

- **Macros may return Class objects and `clojure.core`-qualified special
  heads.** A class inside a macro expansion, as in `(defmacro m []
  [String])`, is re-read as the class symbol that names it (an anonymous
  `reify` class raises a named error), and `(clojure.core/defmacro …)`,
  `(clojure.core/binding …)` and `(clojure.core/ns …)` analyze like their
  bare heads. Emmy's `defgeneric` and sci-macro output load.

- **A destructured `deftype` / `defrecord` method parameter shadows a field
  of the same name.** `(f [_ {:keys [a]}] a)` answers the argument's `a`, not
  the field's, as on the JVM.

- **`(import '[java.util.concurrent Semaphore])`** accepts the vector prefix
  spelling, as the ns `:import` clause already did.

- **NaN-keyed maps keep their values.** `reduce-kv`, `update-keys`,
  `update-vals` and printing walk entries, so a key that is not `=` to itself
  (`##NaN`, or a list holding it) no longer loses its value or prints a
  phantom `k nil` entry.

- **`(.getStackTrace (Thread/currentThread))`** answers an empty array, so
  test.check's clojure.test reporter shows a failing property's shrunk
  counterexample instead of raising a missing-member error.

- **`wasm/component-invoke` accepts a `wasm/load-component` handle** instead
  of refusing it as a non-string path, and dropping a resource of a
  single-module component names the missing resource table instead of
  reporting a guest trap.

- **`cljw.json/write-str` and `read-str`** call clojure.data.json at call
  time, so `with-redefs` of the data.json var reaches them, and both carry a
  docstring and arglists.

- **`java.io.File` `.list`, `.listFiles`, `listRoots` and the constructor
  survive a collection mid-build**, where a GC during the call could return a
  short or empty result.

- **A `defmacro` name with reader metadata** no longer risks a ReleaseSafe
  panic during analysis.

## [1.14.12] - 2026-10-01

### Added

- **`clojure.edn/read` over a reader.** `(clojure.edn/read (java.io.PushbackReader.
  (java.io.StringReader. "{:a 1}")))` answers `{:a 1}`, reading one form per call
  from a persistent cursor, so successive reads walk the stream as on the JVM.
  The `:eof` option and the end-of-input error behave as in clj.
  `clojure.edn/read` now carries its JVM arglists and docstring.

- **`user.home` and friends from the environment.** `(System/getProperty
  "user.home")` reads `$HOME`. `java.io.tmpdir` is `/tmp` whatever `$TMPDIR` says,
  which is the JVM's Unix default. `getProperty` and `getProperties` read one
  static table, so the two can no longer disagree.

### Fixed

- **`with-precision` rounds BigDecimal arithmetic and reports inexact results.**
  `(with-precision 3 (/ 1M 3))` is `0.333M`. Every `:rounding` mode (HALF_UP,
  HALF_EVEN, CEILING and FLOOR among them) matches `java.math.RoundingMode`, precision 0
  means unlimited, and an inexact result under `:rounding UNNECESSARY`, or a
  non-terminating `(/ 1M 3)` outside `with-precision`, raises
  ArithmeticException as in clj.

- **Signed-zero map and set keys match the JVM.** `0.0` and `-0.0` are one key
  for `get`, `assoc`, `contains?`, `dissoc`, `disj`, `=`, `hash`, transients and
  HAMT collections, so `(get {0.0 :z} -0.0)` is `:z`. A literal that repeats a
  key, such as `{0.0 1 -0.0 2}`, `#{0.0 -0.0}`, `{##NaN 1 ##NaN 2}` or
  `#{##NaN ##NaN}`, raises IllegalArgumentException "Duplicate key" in source,
  `read-string` and `clojure.edn/read-string`. NaNs computed at run time stay
  distinct keys, as in clj.

- **Sorted seqs are not lists.** `(list? (seq (sorted-map 1 2)))` is false and
  `(= (seq (sorted-map 1 2)) [[1 2]])` is true, with printing unchanged.
  `keys` and `vals` still raise for non-map seqables (AD-071).

- **Empty `reify` sections construct an instance.** `(reify)`, `(reify
  Object)` and a protocol section with no method impls return an instance, as
  on the JVM. A non-symbol in section position still raises.

## [1.14.11] - 2026-09-27

### Added

- **`ThreadPoolExecutor$AbortPolicy` is available as a rejection handler.**
  `(ThreadPoolExecutor. 1 1 0 TimeUnit/MILLISECONDS (LinkedBlockingQueue. 1)
  nil (ThreadPoolExecutor$AbortPolicy.))` throws
  `RejectedExecutionException` on a `.submit` once the pool and queue are
  full. A handler the constructor cannot honour now raises an error instead
  of silently behaving as abort.

### Fixed

- **`NoSuchMethodException` can be caught, as in clj.** `(catch
  NoSuchMethodException _ nil)` and `(catch java.lang.NoSuchMethodException
  _ nil)` now compile; the class sits under `ReflectiveOperationException`.
  Namespaces that probe optional JDK methods this way no longer fail to load.

- **`contains?` on a String or array truncates Number keys, and `get` indexes
  Java arrays.** `(contains? "abc" 1.5)` and `(contains? "abc" 1N)` are
  `true`, `(contains? "abc" 5.0)` is `false`, and a non-number key such as
  `:a` or `nil` throws `IllegalArgumentException`. `(get (int-array [1 2]) 1)`
  is `2`; an out-of-range or non-integer index returns `nil` or the
  not-found value.

- **BigDecimal arithmetic honours the `with-precision` MathContext.**
  `(with-precision 3 (+ 1.2345M 2.3456M))` is `3.58M` and `(with-precision 3
  (* 1.2345M 2.3456M))` is `2.90M`. `:rounding` applies too: `(with-precision
  3 :rounding HALF_EVEN (+ 1.245M 0M))` is `1.24M`, and `(with-precision 3
  :rounding DOWN (/ 1M 6M))` is `0.166M`.

- **Collection metadata survives `empty`, list `conj` and a dissoc to
  empty.** `(meta (empty (with-meta [1] {:m 1})))` is `{:m 1}` for vectors,
  subvecs, maps, sets, lists, sorted maps and sorted sets; a generic seq still
  empties to a meta-less `()`. `(conj (with-meta '(1) {:m 1}) 2)` and
  `(dissoc (with-meta {:a 1} {:m 1}) :a)` keep `{:m 1}`.

- **Sorted maps and sorted sets accept metadata.** `(with-meta (sorted-map 1
  2) {:m 1})` carries `{:m 1}`, and it survives `assoc` and `conj`.

- **`bigdec` handles scientific and large doubles without narrowing to a
  64-bit integer.** `(bigdec 1.0e20)` is `1.0E+20M`, `(bigdec 1.0e-20)` is
  `1.0E-20M`, and `(bigdec "123456789012345678901234567890.5")` is
  `123456789012345678901234567890.5M`.

## [1.14.10] - 2026-09-26

### Added

- **`Executors/newSingleThreadScheduledExecutor` and `.scheduleAtFixedRate`
  are available.** `(.scheduleAtFixedRate pool runnable 0 1
  TimeUnit/MILLISECONDS)` runs the task repeatedly and returns a future that
  `.cancel` stops (`.isCancelled` is then `true`). The executor takes an
  optional `ThreadFactory`.

- **`ThreadPoolExecutor` supports `.shutdownNow`.** It shuts the pool down,
  cancels queued tasks and returns them as a collection; a task already
  running completes and its `.get` still returns its value.

### Fixed

- **Metadata on a value that cannot carry it is an error, as in clj
  (ADR-0200).** `^:m "s"`, `^:m 1`, `^:m :k`, `^:m nil`, `^:m #"re"` and a
  tagged literal read to such a value (`^:m #inst "..."`) raise
  IllegalArgumentException ("Metadata can only be applied to IMetas") in
  source, `read-string`, `clojure.edn/read-string` and inside a quoted form;
  the meta used to be dropped silently. The reader attaches meta as clj's
  does: merged onto the value's existing meta, and reset in place on an atom,
  agent, ref, var or namespace returned by a tag reader. `^meta` on a tagged
  literal that reads to a collection, record or queue now attaches in source
  too. `^[String] x` reads as `{:param-tags [String]}` (clj 1.12), and an
  invalid meta form (`^1 x`) is IllegalArgumentException with clj's message,
  reported before the target is read. `with-meta` and `meta` now work on a
  PersistentQueue.

- **`derive` rejects a Class parent, as in clj.** `(derive 'p/x String)`
  throws `ClassCastException`, and `(derive (make-hierarchy) 'p/x Object)`
  throws. A Class child with a named parent stays valid: `(derive
  (make-hierarchy) Object 'root-type)`.

- **`parents` and `ancestors` expose a Class's supertypes, as in clj.**
  `(parents String)` and `(ancestors String)` return String's six supertypes,
  including `Object`, merged with any explicit hierarchy entries.
  `(ancestors Object)` is `nil`.

- **`clojure.edn/read-string` with an options map throws at EOF unless
  `:eof` is given, as in clj.** `(clojure.edn/read-string {} "")` throws, also
  for a source holding only a comment or a `#_` form; the one-argument
  overload still returns `nil`. `(clojure.edn/read-string {} "#_1 2")` is
  `2`. A `nil` or non-map options argument now throws.

- **`parse-uuid` and `UUID/fromString` accept the JVM's legacy group forms.**
  `(parse-uuid "1-2-3-4-5")` is `#uuid "00000001-0002-0003-0004-000000000005"`,
  a leading `+` on a group is accepted, and an overlong group is truncated to
  its field width. An empty group, as in `"1--1-1-1-1"`, still returns `nil`.

- **`clojure.repl/doc` shows docstrings for `clojure.data.csv/read-csv`,
  `monitor-enter` and `monitor-exit`.** Their `:doc` and `:arglists` now live
  in the var meta, so `(meta #'monitor-enter)` carries `:arglists ([x])` and
  `find-doc` and nREPL info/eldoc see them.

## [1.14.9] - 2026-09-26

### Added

- **`clojure.java.shell` over a native `cljw.process/run` (ADR-0199).** `sh`,
  `with-sh-dir` and `with-sh-env` run any host program by argv (never through
  a shell) and return `{:exit :out :err}`; a non-zero exit is data. `:in` is
  fed concurrently, so a large input cannot deadlock; `:env` replaces the child
  environment as JVM `sh` does. A child process escapes every in-process
  containment, so `run` is refused under `CLJW_FS_ROOT` or inside
  `cljw.eval/with-budget` (`restriction.zig`, one predicate for both), and a
  worker thread blocked in it no longer holds up a collection. This is the seam
  for driving native tools unchanged: AutoPDF's Clojure client runs the Go
  `autopdf` CLI and renders the same PDF on cljw, clojurust and the JVM.

- **The primitive-wrapper constructors.** `(Long. x)`, `(Integer. x)`,
  `(Short. x)`, `(Byte. x)`, `(Double. x)`, `(Float. x)`, `(Character. c)` and
  `(Boolean. x)` (and their `new` spellings) answer the plain cljw value, so
  the result joins arithmetic, `=`, coercion and `str`. Strings parse as the
  JVM ctors do (NumberFormatException when malformed or out of range). An
  argument no ctor accepts raises IllegalArgumentException "No matching ctor
  found for class …", which is now also what any constructor-less class
  answers when given arguments. Two recorded divergences: `(if (Boolean.
  "false") …)` takes the false branch (AD-073), and `(Short. 7)` / `(Byte. 7)`
  answer 7 because cljw cannot tell them from `(Short. (short 7))` (AD-074).

### Fixed

- **A duplicate map key or set element is an error, as in clj (ADR-0200).**
  `{:a 1 :a 2}`, `#{1 1}` and `#:a{:b 1 :a/b 2}` raise IllegalArgumentException
  ("Duplicate key: :a") in source and in `read-string` /
  `clojure.edn/read-string`, instead of silently keeping the last entry.
  Source is checked as it is read, so a duplicate in a destructuring map or a
  macro argument is caught too. `read-string` checks by value and in source
  order, so `{1 :a 1N :b}` is caught and an earlier missing tag reader is still
  the error reported. `#(...)` params are clj-style gensyms (`p1__N#`), so two
  identical `#()` literals are distinct forms and `#{#(inc %) #(inc %)}` holds
  two fns. `defn` and `defmacro` let an attr-map's `:doc` or `:arglists` win
  over the docstring and the synthesized arglists, as clj does.
- **The reader splits tokens and ends comments where clj's does (ADR-0200).**
  `@`, `^`, backtick and `~` now end a symbol, keyword or character token, so
  `[a@b]` reads as `[a (clojure.core/deref b)]` instead of the symbol `a@b`
  (`'` and `#` stay constituents, as in clj). A `;` or `#!` comment ends at a
  carriage return as well as a line feed, so a CR-only source no longer loses
  the forms after its first comment. `~x` and `~@x` read as data outside a
  syntax-quote are the lists `(clojure.core/unquote x)` and
  `(clojure.core/unquote-splicing x)`, where `read-string` used to raise.
- **A `future` blocked in a host call no longer stalls every collection.** A
  worker waiting in `Thread/sleep`, a `cljw.net` accept, read, write or dial,
  or a `cljw.http.client` request was not a safepoint, so a collection another
  thread requested waited for the call to return, and forever if the peer never
  answered. Each of these waits now runs under `safepoint.blocking`, which
  counts the worker as parked for the call. The `cljw.http.server` accept,
  request read and response write are bracketed the same way; the response is
  first copied out of the handler's value, so a slow reader cannot stall a
  collection either.

- **A `future` waiting on a promise, a future, an agent or a Thread no longer
  deadlocks the collector.** `@(promise)`, `@(future ...)`, `(await agent)`
  and `(.join thread)` on a worker, an idle `Executors` pool worker, and
  `(realized? delay)` while another thread forces it all waited uncounted, so
  the next collection waited for them, and their waker (often the collecting
  thread) waited for it: a deadlock. The latch under every deref now counts
  its waiter as parked, the pool's idle wait and Thread join are bracketed,
  `realized?` on a delay reads its state lock-free (which also stops a thunk
  that asks about its own delay from deadlocking), and the ref-read and
  LinkedBlockingQueue spin locks poll the safepoint. A timed deref with a huge
  timeout no longer overflows.

- **An error inside a loaded or required file shows that file's source.** A
  script's uncaught error rendered its snippet from the script itself: an
  error at `lib.clj:3` printed line 3 of the running script. The script
  runner now resolves the snippet by the error's file, and a file
  `load-file`d again after an edit renders against its new text, not the
  first version's.

- **`cljw.http.client` could return a response with `:status` missing.** The
  response map was built in an unrooted local, and a collection at the body
  allocation swept it half-built. The http server's request map and the wasm
  component `exports` and result lift had the same shape. Each now builds
  inside a fabrication region.

- **`load-file` and `load-string` read each form after the previous one ran.**
  They read the whole text up front and evaluated one `(do …)`, so `::kw` and
  syntax-quote in a loaded file resolved in the caller's namespace, not the
  file's `(ns …)`. They now share the `require` loader's loop, label errors
  with the file, and restore the caller's namespace afterwards. A `def`
  evaluated from a locationless caller (such as `load-string` itself) also kept
  its computed metadata unevaluated (`^{:k (+ 1 2)}` stayed a list), which left
  every `deftest` loaded this way with an uncallable `:test`; computed metadata
  is now always evaluated.

## [1.14.8] - 2026-09-25

### Added

- **`docs/examples/polyglot/`: every guest language through the FFI, gated.**
  A C kernel (`zig cc`, 2.3 KB) and a Zig kernel (267 B) over `wasm/load` +
  `wasm/call` with guest-owned buffers, a `no_std` Rust module (401 B), a
  wit-bindgen Rust component required as a namespace (records, lists and
  `result` as Clojure data), and a Go program run as a WASI command through
  `wasm/run` with argv, env and stdin. `hosts.cljc` is one program that prints
  the same value on `cljw`, `cljrs` and JVM Clojure. `phase16_wasm_polyglot`
  runs the committed guests, rebuilds each one whose toolchain is on PATH from
  the recipe in its source header, and diffs the hosts, so the README's
  polyglot claims fail in CI before they fail for a reader.

### Changed

- README: the typed-component example now names a committed fixture, and its
  result reads `[:ok {...}]`, which is what a WIT `result<T, E>` returns.
  Documented from the demo: a void export that takes an `f64` has no JIT call
  shape and needs `{:engine :interp}` or a result value, and the linker's
  default 1 MB shadow stack makes a C module ask for 17 pages.

## [1.14.7] - 2026-09-15

### Added

- **`wasm/load-component` takes the same budget map as `wasm/load`**:
  `(wasm/load-component "c.wasm" {:fuel N :max-memory-pages M})`. A missing
  axis keeps zwasm's finite default (1e9 fuel, 4096 pages); `0` or a negative
  value removes that cap for a trusted component. Fuel is per instance and is
  not refilled between calls, so an exhausted handle stays exhausted and a
  fresh load is the refill. `:engine` and `:timeout-ms` are refused, because a
  component is pinned to the interpreter and no wall-clock deadline is
  enforced on this path; a caller that needs one puts it around the call.

### Fixed

- **Running out of fuel is reported as running out of fuel.** A guest that
  consumed its whole budget surfaced as the generic trap message ("trapped
  (e.g. divide-by-zero, out-of-bounds, or an unreachable instruction)"), the
  one cause that cannot be confused with those three. `wasm/call` now raises
  `'<export>' exhausted the module's fuel budget` and a component call raises
  `component exhausted its fuel budget`; a genuine guest fault still reads
  `trapped`. A component that fails to open now names the engine's reason
  (`UnsupportedWasiImport`, for one) instead of "failed to compile or
  instantiate".

- **A Rust `wasm32-wasip2` component built against `std` now instantiates.**
  Any such guest that links `std::fs` imports `wasi:filesystem/types@0.2`
  `metadata-hash-at`, which the embedded engine had no row for, so the whole
  component failed to link before a single instruction ran; a `println!`-only
  guest passed because it never linked the filesystem interface. Fixed in the
  engine (see Changed), together with the 0.2 filesystem error-code ordinals
  past `no-lock`, which were one too high and reported every "unsupported"
  stub as "Not a tty". Still not there on the 0.2 path: `std::fs` reads and
  writes (`read-via-stream` / `write-via-stream` stay engine stubs), which now
  fail with `ENOTSUP` instead of instantiating nothing.

### Changed

- **The embedded Wasm engine is zwasm v2.7.0 plus two fixes, pinned to the
  `cljw` branch of this project's fork (BuddhiLW/zwasm) until upstream carries
  them.** v2.7.0 brings cross-module composition on the default engine,
  engine observability hooks, and one behaviour change: a module the JIT judges
  invalid is refused on the default engine instead of silently rerun on the
  interpreter. The two fixes, both found from cljw and sent upstream as PRs:
  a component's second and later exported interfaces resolve (they were
  invisible to `wasm/component-exports` and `require-component`), and the
  wasip2 `std` fix above. The engine bump grows the shipped binary from
  7.55 MB to 8.14 MB (8,141,512 bytes, macOS arm64 reference build), under
  the 8.8 MB ceiling; the size figures in the README, `docs/landscape.md`
  and `bench/RELEASE_METRICS.md` follow.

## [1.14.6] - 2026-09-15

### Added

- **`ns-unmap`** (`clojure.core`, upstream surface). Removes a name from a
  namespace's mappings and refers. The Var survives the unmapping, as on the
  JVM: compiled code and a captured `#'ns/x` keep working through it. It moves
  to the namespace's `retired` list, which the GC root walk visits and
  namespace teardown frees, so an unmap can neither dangle nor leak.

### Fixed

- **Re-requiring a Wasm component no longer leaves the previous build's Vars
  interned.** `cljw.wasm/require-component` tags every Var it interns; on a
  re-require the tagged Vars the new export table no longer has are retired:
  their root is first rebound to throw `component <path> no longer exports
  \`name\``, so a caller holding the old Var gets a catchable error instead of
  a call into the previous instance, and that instance stops being reachable
  through it. Exports the new build keeps retain their Var identity, and a Var
  the user `def`ined (or `def`ined over an export name) is never touched.

- **Hashing or comparing a String that is not valid UTF-8 no longer ABORTS
  the process.** `(hash (slurp "some.wasm"))` core-dumped cljw and took the
  REPL with it; `(compare a b)` on such a String did the same. A cljw String
  is raw bytes (AD-009), so it can hold anything a file or a Wasm guest buffer
  contains, but `javaStringHashCode`, `hashUnencodedChars` and
  `javaStringCompareTo` all walked it with `std.unicode.Utf8View.initUnchecked`.
  That call promises the caller has already validated; its iterator reads past
  the end of a truncated sequence and trips `unreachable`, which is a process
  abort in every safe build, not a catchable Clojure error.

  All three now decode through `utf8_total.Iterator`, a drop-in for
  `std.unicode.Utf8Iterator` that is total over arbitrary bytes and substitutes
  U+FFFD exactly as the JDK does: one replacement per MAXIMAL SUBPART, not per
  byte, so `{0x41, 0xE2, 0x82}` hashes as `['A', U+FFFD]` on both runtimes.
  The two places the JDK departs from the plain Unicode reading are
  reproduced (`ED` accepts `80..BF` as its second byte; a complete 3-byte
  surrogate encoding is ONE ill-formed span), measured against JDK 25 and 26.
  Hashing has to be total, because a value that cannot be hashed cannot be put
  in a map, and a String must not become un-mappable for a reason the caller
  cannot see. Valid UTF-8 decodes byte-identically to what the checked
  iterator produced, so the JVM parity values are unchanged. `compare` falls
  back to byte order when the decoded sequences tie, so it returns 0 exactly
  when the strings are `=`. Two distinct invalid strings may now hash equal,
  which a hash is allowed to do; `=` still compares the bytes.

## [1.14.5] - 2026-09-11

### Added

- **`java.io.File` publishes `getCanonicalFile` and `getAbsoluteFile`.** The
  String-returning halves (`getCanonicalPath`, `getAbsolutePath`) were already
  there; the JVM publishes both spellings of each resolution, so calling the
  File-returning twin raised "No implementation of method". Both are now
  registered and return a usable `File`.

### Fixed

- **`rationalize` accepts a BigDecimal, and works from its exact decimal.**
  `(rationalize 1.1M)` raised "expected number": the BigDecimal tag fell into
  the not-a-number arm, so the one numeric type that is already an exact
  decimal was the one type `rationalize` refused. It now reads the value as its
  unscaled significand over `10^scale` and gcd-reduces that, with no float in
  the path, so every digit survives: `(rationalize 12345678901234567890.5M)` is
  exact where a double round-trip would lose the low digits. A value whose
  trailing digits are zeros reduces to the integer (`(rationalize 1.0M)` is
  `1`), which is a machine integer in cljw where clj has a BigInt (AD-072; the
  values are `=`).
- **A value that is not a form evaluates to itself.** `(eval f)` on a function
  value raised, and so did `(eval #"a+")` and `(eval (atom 1))`, where clj
  answers the value: an object that is not source has nothing left to compile.
  cljw sent every argument through the analyzer, which has no rule for a
  runtime object and reported it as unanalyzable. Only the tags that can *be* a
  form now reach the analyzer (a list or seq, a symbol, and the collection
  literals whose elements still need evaluating); everything else is returned
  unchanged. `clojure.core-test.eval` goes from 2 errors to green.
- **A `re-matcher` is `Indexed`, so `nth` reaches its capture groups.**
  `(nth m 2)` raised "No implementation of method `-nth` on protocol `Indexed`"
  for a Matcher, where clj answers group n. The Matcher's methods were all
  registered under an empty protocol name, so nothing could reach them through a
  protocol at all; `-nth` now registers under `Indexed`. The semantics are clj's,
  including one asymmetry the oracle showed: a negative index raises in the
  2-arity but answers the not-found value in the 3-arity.
  `clojure.core-test.nth` goes from 7 errors to green.
- **`int`, `byte` and `short` enforce their own range, and range-check a double
  before narrowing it.** `int` shared one body with `long`, so it never checked
  the int range: `(int 2147483648)` passed the value straight through where clj
  raises. The two are separate now. A double is also range-checked before it
  narrows, so `(byte 127.9)` raises instead of quietly becoming `127`; clj picks
  that behaviour by static type, which cljw has no equivalent of, so it applies
  uniformly (AD-070). An out-of-range cast now raises cljw's
  `IllegalArgumentException` rather than a `ClassCastException`, matching what
  clj throws and what user `catch` clauses expect. `NaN` follows clj's own
  asymmetry: `0` for `int` / `long`, a raise for `byte` / `short`. The results
  stay Longs, since cljw has no Integer / Byte / Short (AD-069).
- **`derive` validates the shape of its tag and parent.** cljw accepted any
  value in either position, so `(derive :user/tag 42)` silently installed a
  number as a parent and `(derive ::a :b)` accepted an un-namespaced parent into
  the GLOBAL hierarchy, where one library's `:shape` can collide with another's.
  clj's 2-arity is deliberately stricter than its 3-arity on exactly that point
  (a hierarchy value you pass in is your own), and both arities are now checked
  the same way clj checks them. `clojure.core-test.derive` goes from 11 failures
  to 1. The residual one is deliberate: cljw permits a CLASS parent, where clj
  raises `ClassCastException`, because ADR-0109 makes a host class a first-class
  hierarchy participant -- `(derive ::x Object)` then `(isa? ::x Object)` is a
  tracked behaviour in `test/e2e/phase14_opaque_host_class.sh`, and the `isa?`
  is false without that derive, so the edge is real rather than implied by
  `Object` being the universal supertype.
- **`assoc!` accepts a trailing key with no value, as clj does.** clj makes
  `assoc!` deliberately more lenient than `assoc`: the missing value is `nil`,
  so `(assoc! (transient []) 0 1 1)` is `[1 nil]`. cljw applied `assoc`'s
  even-arity rule and rejected it. The arity check also ran second, so
  `(assoc! tm :b)` reported a key-without-value error where clj reports an
  `ArityException`; too few args is an arity fault, and it is checked first now.
- **A live transient is readable and callable, not just `get`-able.** D-199 made
  a transient a first-class read target, but only `get` on a transient map and
  vector was wired: `((transient m) :k)` raised "Cannot call value of type",
  `(:k (transient m))` and `(get (transient #{x}) x)` quietly answered `nil`.
  All three now behave as clj does. The arities are clj's and are deliberately
  not uniform, each checked against the oracle: a transient map and a transient
  set take an optional not-found (a persistent set is 1-arity only), while a
  transient vector is 1-arity and throws on a bad index. Pinned in
  `test/diff/clj_corpus/transient_read_surface.txt`.
- **`(transient nil)` throws instead of answering an empty transient vector.**
  clj throws; returning a value turned a typo into a silently empty
  accumulator.
- **`conj!` on a transient map accepts `nil` and another map.** Persistent
  `conj` on a map already merged an overlay map and treated `nil` as a no-op;
  the transient twin still required a `[k v]` pair and raised
  `IllegalArgumentException` for either, which also broke
  `(into (transient {}) {…})`. Both now behave as clj does, verified against the
  oracle and pinned in `test/diff/clj_corpus/transient_conj_merge.txt`.
- **Reader metadata on a collection literal survives macroexpansion.** A macro's
  return value is converted back into a Form so it can be re-analyzed, and that
  converter rebuilt a collection from its elements only, never reading the
  Value's metadata, so `^:a []` came back stripped. The symbol arm had carried
  metadata across since ADR-0110; collections were missed. Because every
  `clojure.test` assertion sits inside a `deftest` body, this made correct
  functions fail their own upstream suite while passing every direct probe:
  `clojure.core-test.group-by` went from 6 failures to 0 with no change to
  `group-by` itself.
- **Golden snapshots in the hive-test fixture are anchored, and a missing one
  now fails instead of being captured.** `clojure.java.io/resource` returns nil
  for every name by design (D-359: cljw has no classpath resource loader), so
  hive-test's classpath walk-up resolved a golden against the process working
  directory. A session rooted at the repository therefore wrote an unreviewed
  baseline at the repo root and reported success. The fixture now anchors
  through hive-test's own `*project-root*` / `*store*` seams and refuses to
  create a reviewed golden unless `UPDATE_GOLDEN=true`; `cljw -M:anchor-test`
  covers the rule on both runtimes without touching disk.

## [1.14.4] - 2026-09-10

### Fixed

- **Lazy sequence bodies use the complete Seqable/ISeq boundary.** Strings
  yield characters, arrays and host collections yield their elements, and
  custom Seqable/ISeq implementations work through the same accessors as
  native collections. Invalid bodies and invalid custom `seq` return values
  raise the appropriate exception. Nested lazy bodies realize iteratively
  and cache their terminal sequence; successful realization releases the
  captured thunk safely when readers or metadata copies run concurrently.
- **Array sequences retain their backing array**, so later element updates
  remain visible through eager and realized lazy views.
- **Sequence consumers retain values across GC callbacks.** Custom sequence
  heads and cursors survive iterator advancement, equality, CSV traversal and
  sorted bounds, including callbacks that explicitly request collection.
- **Redefining a `deftype` or `defrecord` no longer corrupts memory.** The
  displaced type descriptor is retired for the life of the process instead of
  being freed, so values, call sites and protocol tables created against the
  old definition stay valid. Reloading a namespace at the REPL previously read
  freed memory, which surfaced as an unrelated-looking error whose text varied
  between runs.
- **Two types with the same short name in different namespaces are now
  distinct.** The type registry is keyed by the fully qualified name, so
  `aaa/Point` and `bbb/Point` no longer overwrite one another for qualified
  references, record literals, printing, field access and `class` identity. A
  bare `Point` still resolves to the most recently defined one; that remainder
  is tracked and is not a regression.

### Changed

- **The AOT bytecode wire format is version 11** (was 10). Caches written by an
  earlier build are rejected and regenerated; no user action is required.
- **Nine end-to-end shell scripts became native Clojure test suites.** Error
  cases that a shell could only check by exit code or by grepping merged output
  are now real `thrown-with-msg?` assertions, and value cases that were compared
  as printed text are compared as values.

- **Lazy sequence regressions run as native Clojure suites**, including CLI
  allocation torture. The suite runner accepts namespace selectors and rejects
  unknown selections. Seeded hive-test laws, mutation witnesses and reviewed
  goldens cover the lazy Seqable boundary.
- **Sequence extension and method-overload shell checks now run their value
  assertions in native Clojure**, preserving isolated native-tag dispatch tests
  and the optional data.priority-map integration.

## [1.14.3] - 2026-09-07

### Fixed

- **Variadic `apply` preserves lazy tails after bounded method selection.**
  Infinite argument sequences work when the callee consumes a finite prefix;
  exact finite calls retain fixed-arity dispatch. `concat`, `mapcat`, `cycle`,
  `repeat`, `nthnext`, `select-keys`, `shuffle` and `subvec` now match their
  JVM sequence and validation boundaries. `cons` accepts empty collection tails
  while retaining its Cons identity. `apply list` constructs a fresh list from
  any finite argument sequence, preserving order and dropping source metadata.
- **A `def` inside a function binds the Var declared in that function's
  namespace**, even when called from another namespace. Both backends retain
  the analyzed Var identity, including unbound declarations and restored AOT
  functions. Bytecode format v10 records that identity; rebuild older compiled
  artifacts. This also fixes the upstream Var watch tests.
- **`slurp`, `clojure.java.io/reader` and `line-seq` read procfs, sysfs and
  FIFO files to the end.** They returned empty for any file whose reported size
  is 0 but which yields bytes (`(slurp "/proc/loadavg")` was `""`), because the
  whole-file read trusted the stat size as a stop. The size is now a capacity
  hint only and the read continues until a real end of file; the same path
  serves `load-file`, `require`, `deps.edn`, `wasm/load` and the script runner.

### Changed

- **61 shell regression groups now run as native Clojure test suites**,
  preserving 800 named assertions. Seeded runtime laws and hive-test mutation
  witnesses cover sequence boundaries and existing string behavior.

## [1.14.2] - 2026-09-06

### Added

- **`(wasm/engine handle)`** returns the engine selection a handle was loaded
  with (`:auto`, `:jit` or `:interp`), so engine-dependent behaviour is
  discoverable (ADR-0196).
- **`bench/wasm_percall.clj` measures one `wasm/call` crossing in nanoseconds**
  (`cljw -cp bench -m wasm-percall`), per engine and thread, with a plain
  Clojure call as the platform constant; a cljw program end to end, no shell.
  Every other wasm workload loops inside the module and crosses the boundary
  once per process, so a per-call cost of any size could not show there; this
  is the other axis, with its datum (`bench/wasm-percall-latest.yaml`) rendered
  into the bench README like the rest.

### Changed

- **A wasm trap names the export, its signature, the engine and the remedy.**
  `wasm/call` now raises `wasm/call: 'gpr4_void' (i32 i32 i32 i32) -> () trapped
  on the auto (JIT-first) engine (...); the JIT engine has no call dispatch for
  a zero-result export of this shape; load the module with {:engine :interp},
  or give the export a result` instead of a bare "WebAssembly module trapped".
  The known engine gaps live in one table (`runtime/cljw/wasm/gaps.zig`); the
  default engine stays `:auto`, and the `wasm/load` docstring states the
  per-call crossing cost of each engine (ADR-0196).
- **`wasm/call` resolves an export's signature once per handle.** The
  signature used to size the argument and result buffers was re-resolved by
  name on every call, which on the JIT engine re-parses the module; it is now
  cached on the handle after the first call. The engine's own by-name lookup
  inside the invoke is unchanged (an upstream zwasm item).

## [1.14.1] - 2026-09-06

### Changed

- **`cljw` runs the program on a runtime thread it spawns, never on the
  process's initial thread** (ADR-0195). On Linux the JIT engine's per-call
  stack query is ~26 us on the initial thread and under 1 us on any other, so
  a `wasm/call` on the default `:engine :auto` drops from ~16.5 us to ~1.2 us
  per call (measured with `.dev/bench/ffi_boundary/engine_thread_matrix.clj`;
  the interpreter engine is unchanged at ~0.4 us). The runtime thread and every
  worker thread now share one explicit stack geometry (16 MiB stack, 6 MiB
  guard budget), asserted at compile time instead of described in prose.
  Single-threaded targets (wasm32-wasi) are unaffected; if the thread cannot
  be spawned, `cljw` prints one line to stderr and runs on the initial thread
  as before.

## [1.14.0] - 2026-09-06

### Changed

- **The embedded Wasm engine is zwasm v2.6.0** (was v2.5.0). No change to
  `wasm/load`, `wasm/call` or `wasm/run`: the one embedding-API difference
  (zwasm #257 widened the captured-run stdin type) is absorbed internally, and
  `:stdin` still takes a string. The per-call JIT cost measured in
  `.dev/wasm_percall_findings.md` is unchanged by this bump; it is addressed
  separately.

- **The wasm FFI benchmark measures again, and now says what it measures.**
  `bench/wasm_bench.sh` had been driving `cljw.wasm/load-wasi` + `wasm/fn` —
  an API that does not exist — so every workload failed its output check and
  the harness reported SKIP for all six. Ported to the shipped `(wasm/load path
  opts)` + `(wasm/call m "fn" args…)` surface, given an `--engine=` selector,
  and its banner corrected: cljw's zwasm default is JIT-first, so the default
  column was never "interpreter vs wasmtime JIT". First numbers: cljw's
  embedded zwasm lands **1.4-4.4x wasmtime** on the compute-bound workloads,
  and the JIT tier is **15.5x** its own interpreter fallback.

- **Benchmark tables and charts are generated from a committed datum.** Each
  harness writes a `--yaml` measurement file; `bench/gen_cross_table.py`
  (Markdown) and the new `bench/gen_charts.py` (dependency-free SVG) render
  from it through a shared domain model, `bench/bench_domain.py`. Numbers from
  two machines can no longer end up in one table.

- **hive-test trifecta is verified natively on cljw.** A committed
  source-coordinate project runs hive-test's `.cljc` golden, property, and
  mutation facets inside cljw: 100 generated cases and two caught mutants.
  This uses pinned Git sources for both hive-test and test.check; no Maven JAR
  enters cljw's source-only dependency closure.

- **Differential and corpus harnesses are Clojure-native.** Babashka now owns
  process supervision while shared `.cljc` code owns bencode/nREPL exchange.
  Corpus replay uses one live cljw runtime per corpus and a fresh session per
  expression; only the CLI-binding corpus uses cljw's CLI context. The old
  Bash replay/sweep and Python nREPL clients are gone.

- **Behaviour tests move to a cljw-native tier.** 25 bash e2e scripts that
  spent one `cljw` process per assertion became `clojure.test` suites under
  `test/clj/suites/`, run by cljw itself — 803 process spawns out of the gate,
  and the suites re-run over an nREPL with no rebuild. What stays in bash is
  the CLI surface (exit code, stderr, argv) and anything that needs the
  process itself. No runtime behaviour changes.

### Added

- **`clojure.walk/macroexpand-all` now works.** It previously threw
  "not yet supported": it had been left as a deliberate stub until
  `macroexpand` was callable at runtime, and that prerequisite has long since
  shipped. It is now the same definition as the JVM's — a `prewalk` that
  macroexpands every seq it visits — so `(macroexpand-all '(when true 1))` is
  `(if true (do 1))`. Like the JVM's, it is not quote-aware and walks into
  quoted forms.

### Fixed

- **`clojure.string/replace` and `split-lines` match JVM edge semantics.**
  `replace` now applies the source object's string representation while still
  rejecting `nil`, and an empty string match inserts at every codepoint
  boundary. `split-lines` now removes every trailing empty field, including
  inputs made entirely of line terminators.

- **`when-not` expands to clj's shape.** `(macroexpand '(when-not c x))` was
  `(if c nil x)` where clj gives `(if c nil (do x))`, and `(when-not c)` was
  `(if c nil nil)` against clj's `(if c nil (do))` — the body wrapper was
  folded away for a single or empty body. Every arm now wraps unconditionally,
  as `when` already did. The evaluated result never differed; only the
  expansion did, which `macroexpand-all` had just made visible.

- **`slurp` drains `System/in` to EOF.** `(slurp System/in)` returned `""`
  where clj returns the piped input: the stream-side drain sliced whatever
  happened to be buffered without demand-filling process stdin first, so with
  nothing yet read the remainder was empty. It now blocks pulling stdin to EOF
  before draining, the same way the `*in*` text-reader drain already did, and
  it still returns only the unread remainder after a prior `.read`.

## [1.13.2] - 2026-08-31

### Added

- **`clojure.core/munge`.** Escapes each character illegal in a Java identifier
  as a `_TOKEN_` (the inverse of `clojure.repl/demunge`), preserving the
  argument's type: a string munges to a string, a symbol to a symbol.
  `(munge "foo-bar?")` is `"foo_bar_QMARK_"`. cljw carried `namespace-munge`
  and `demunge` but not the full `munge`; found while writing dev tooling.

- **`clojure.repl/stack-element-str`.** Renders one stack frame as
  `<ns>/<fn> (<file>:<line>)`. cljw has no JVM `StackTraceElement` and only
  Clojure frames, so it takes the cljw-native frame map `{:ns :fn :file :line}`
  (as returned by `stack-trace`) and produces exactly clj's Clojure-frame form,
  e.g. `"clojure.core/map (core.clj:2743)"`.

### Fixed

- **`clojure.repl/demunge` maps the `$` nested-class separator to `/`.**
  `(demunge "clojure.core$map")` now returns `"clojure.core/map"` as in clj;
  cljw reversed the munge tokens but left `$` in place.

- **`slurp` reads from `*in*` and any text reader.** `(slurp *in*)` and
  `(with-in-str s (slurp *in*))` raised "expected string, got host_instance"
  because the `*in*` reader is a cljw-native text reader, not a host stream, so
  it fell through slurp's reader arm. slurp now drains a text reader's unread
  remainder (blocking to stdin EOF for `*in*`), and it respects a prior
  `read-line`, matching clj.

## [1.13.1] - 2026-08-31

### Added

- **`clojure.core/load-file`.** Reads and evaluates every form in the file at a
  given path in order, with `*file*` bound to that path, and returns the value
  of the last form (the clj `(load-file name)` contract). It delegates to
  `load-string` over the file contents, so the vars a loaded file defines are
  visible afterwards exactly as in clj. Found missing while writing the dev
  nREPL loop in cljw.

### Fixed

- **`interpose`, `map-indexed` and `keep-indexed` preserve lazy realization.**
  Each now recurses through a chunk-aware lazy helper instead of realizing its
  whole input, so `(take 5 (interpose :s (repeat :x)))` and the `map-indexed` /
  `keep-indexed` equivalents compose with infinite and large seqs as in clj.
  The helpers are `^:private`, so they stay out of the public surface and out
  of `apropos`.

- **`format` supports the `%C` conversion and nil characters.** `(format "%C"
  \a)` uppercases to `"A"`, and a nil character renders as `"null"` (`%c`) or
  `"NULL"` (`%C`), matching clj's `Formatter`.

- **`double` and `float` reject a Character argument.** `(double \A)` and
  `(float \A)` now throw as in clj, instead of coercing the character's code
  point.

## [1.13.0] - 2026-08-30

### Added

- **`clojure.core/file-seq`.** A lazy depth-first seq of a directory and
  everything under it, defined as the JVM does — a `tree-seq` over
  `.isDirectory` / `.listFiles`. A non-directory yields just itself. Output
  matches clj exactly on the same tree.

- **The dev REPL loop is written in Clojure, not bash or python.** The nREPL
  client lives in `scripts/dev/{bencode,nrepl}.cljc` and is shared by two entry
  points: `scripts/dev_repl.clj` (babashka — it also supervises the server
  process, which cljw cannot do yet) and `scripts/nrepl_client.clj` (cljw
  itself). One implementation, two runtimes, split by a three-function reader
  conditional over the socket. Running it under cljw exercises `cljw.net`
  sockets, byte arrays and UTF-8 length handling on every use, so a regression
  there breaks a daily tool instead of hiding. Its purpose is prototyping
  `clojure.core` changes: redefining a var in the running image takes ~0.13 s
  where the same change through `core.clj` costs a full bytecode rebuild.
### Fixed

- **`find` / `.entryAt` / `(MapEntry. k v)` / `clojure.walk` yield real map
  entries.** A sweep for every site still producing a plain 2-vector where clj
  produces a `MapEntry` — live bugs since `key`/`val` began requiring a real
  entry — found three roots. `clojure.core/find` built `[k (get m k)]`, and
  being receiver-blind that broke every receiver (map / sorted-map / vector /
  record / transient) plus `.entryAt`, which routes through it. `clojure.walk`
  synthesized vector pairs when rebuilding a map. The host constructor
  `(MapEntry. k v)` returned a vector. All now yield entries, so
  `(key (find {:a 1} :a))` works as in clj.

- **`clojure.walk` recurses into map entries.** Its dispatches matched
  `.vector` but not the (now distinct) entry type, so an entry was treated as a
  scalar and nothing *inside* a map was transformed — `keywordize-keys`
  converted the outer key and left nested ones alone. `walk` / `prewalk` /
  `postwalk` now transform an entry's key and val and rebuild an entry, which
  is what clj's dedicated `IMapEntry` branch does. A walk fn may still return a
  plain 2-vector instead of an entry; both are accepted.

- **`(conj map nil)` is a no-op instead of throwing.** clj's
  `APersistentMap.cons` walks `(RT/seq o)`, and the seq of `nil` is `nil`, so
  the map comes back unchanged; cljw raised "expected [k v] vector". Hash,
  array and sorted maps are all fixed. Vectors, sets and lists still take the
  `nil` AS an element (`(conj [1] nil)` → `[1 nil]`) — the no-op is
  map-specific, not a blanket rule.

- **`(nth () 0)` raises instead of answering nil.** The list arm walked the
  tail, so `(nth '(1) 5)` already raised, but index 0 on an EMPTY list never
  entered the walk and fell through to `first`, which answers `nil` for an
  empty list — a silent wrong answer where clj raises `IndexOutOfBounds`. The
  3-arity default form is unchanged (`(nth '() 0 :default)` → `:default`), as
  is `(nth nil 0)` → `nil`.

- **Sorted-map seqs yield map entries, not plain 2-vectors.** `sorted-map`,
  `rseq`, `subseq`/`rsubseq` and `java.util.TreeMap` (which delegates to the
  same walkers) built a 2-element vector per entry, so `(map-entry? (first
  (sorted-map :a 1)))` was `false` where clj says `true`, and `key`/`val` —
  which require a real entry — threw on them. The hash-map path was already
  correct, making the sorted path the odd one out and quietly contradicting
  AD-032's "cljw MapEntry pairs" promise. All three sorted walkers now build a
  `MapEntry`. Print form (`[k v]`) is unchanged.

- **`select-keys` requires an associative (or nil) first argument.** clj runs
  `RT/find`, which casts a non-Associative, non-nil argument to `Map` and
  throws; cljw silently returned `{}`, so `(select-keys "" [:a])` looked like a
  successful lookup of nothing. Maps, vectors and `nil` are unchanged
  (`nil` → `{}`); a string / list / number now raises a catchable error.

- **`merge` adds a 2-vector or map-entry argument AS an entry.** clj's `merge`
  reduces with `conj`, so `(merge {:a 1} [:b 2])` → `{:a 1, :b 2}`; cljw
  iterated each argument's `keys`, which threw on a plain vector. Now
  conj-based, matching clj for map / entry / vector arguments; `nil` arguments
  are still skipped and the 0-arity still returns `nil`.

## [1.12.1] - 2026-08-29

### Fixed

- **`future` / `future-call` / `pmap` convey the creating thread's dynamic
  bindings.** clj's `binding-conveyor-fn` re-establishes the spawning thread's
  dynamic binding frame on the worker, so `(binding [*x* 1] @(future *x*))`
  sees `1`; cljw ran the worker on a fresh thread with only root bindings and
  saw the root value. `future-call` — the single conveyance point that
  `future`, `pmap`, `pcalls` and `pvalues` all route through — now wraps its
  thunk with `bound-fn*`. A worker with no `binding` in scope still sees the
  root value (unchanged).

- **`agent` `send` / `send-off` convey the dispatching thread's dynamic
  bindings.** Same gap as `future`: an action dispatched under a `binding` ran
  against root bindings on the agent's executor. Both now wrap the action with
  `bound-fn*` before enqueue, sharing `future-call`'s single conveyance point.

- **`subvec` coerces a non-integer index instead of crashing.** clj runs
  `subvec`'s start/end through `Number.intValue` (truncate; `##NaN` → 0) before
  the bounds check, so `(subvec [0 1 2] 2.72 3.14)` → `[2]` and
  `(subvec [0 1 2] ##NaN 3)` → `[0 1 2]`; cljw passed the raw value to an i64
  cast that panicked on a float / ratio / NaN. Indices are now `int`-coerced
  ahead of the bounds check, and a non-number index raises a catchable error.

## [1.12.0] - 2026-08-29

### Added

- **`(String. bytes/chars offset length [charset])` range constructors.** clj's
  `String(byte[]/char[], int, int[, Charset])` decodes only the
  `[offset, offset+length)` window, but cljw's constructor capped at 2 args
  (whole array `[+ charset]`), so `(String. (byte-array [104 105 106]) 1 2)`
  raised an arity error where clj yields `"ij"`. The constructor now accepts
  0–4 args: with 3 or 4 args the 2nd/3rd are offset/length and the decode runs
  over that element window (bytes or chars); a 4th arg is the charset (accepted,
  UTF-8 used — cljw is UTF-8-only). An out-of-range window raises
  `index_out_of_range` (catchable, JVM `StringIndexOutOfBounds` parity) rather
  than clamping. `(String. s)` stays 1-arg only.

### Fixed

- **`int?` is fixed-precision; `pos-int?` / `neg-int?` / `nat-int?` accept heap
  Longs.** cljw stores a Long that overflows its inline range as a heap value
  with a `.long` origin; the integer predicates read the tag without consulting
  that origin, so `(pos-int? (bit-shift-left 1 60))` was `false` (clj `true`)
  and `(int? (bigint 5))` was `true` (clj `false` — clj's `int?` is
  fixed-precision, only `integer?` accepts a BigInt). `int?` is now split from
  `integer?`, and all four predicates route through one `isFixedInt` classifier
  (`.integer` or a `.long`-origin heap value), composing the existing
  `pos?`/`neg?` for the sign so a heap Long and a true BigInt are classified
  once.

- **`take` accepts a float / `##Inf` / BigInt count.** clj's `take` compares the
  count numerically (`(pos? n)` / `(dec n)`), so `(take 2.0 [1 2 3 4])` →
  `(1 2)`, `(take 2.9 …)` → `(1 2 3)` (ceil, not truncation), `(take ##Inf …)`
  realizes the whole finite source, and a BigInt count is legal — but cljw's
  eager leaf raised a type error for any non-integer count. It now derives the
  realizable count (integer as-is, positive float as `ceil(n)`, `##Inf` or an
  oversized count as unbounded, `n ≤ 0` / `##NaN` as none, BigInt via its i64
  value). A non-number count raises `type_arg_not_number`.

- **`disj` / `disj!` / `dissoc!` accept a variadic (and single-arg) key list.**
  clj's set/transient removers fold over multiple keys (`(disj #{1 2 3 4} 1 2 3)`
  → `#{4}`, `(disj #{1 2})` → `#{1 2}`), but cljw held all three to a fixed
  2-arg arity and errored. Each now takes a variadic key list and loops the
  removal, mirroring `assoc!`'s existing pair-loop; a 1-arg call returns the
  collection unchanged (clj identity arity). `(disj)` / `(dissoc! t)` still
  error, matching clj.

- **`clojure.string/replace` accepts a map / IFn replacement.** clj treats any
  non-string replacement on a regex match as a function called with the match,
  and a map/keyword/set/vector is `IFn` too, so
  `(clojure.string/replace "aXbXc" #"X" {"X" "-"})` → `"a-b-c"` — but cljw
  whitelisted only fn values and raised a type error for a map. It now invokes
  any non-string replacement through the vtable (cljw's `callFn` already
  dispatches map/keyword/set/vector-as-fn); a genuinely non-callable value
  raises inside the call, as in clj.

- **Ad-hoc hierarchy ops reject malformed input instead of silently returning
  a value.** `(descendants SomeClass)` now throws (clj:
  `UnsupportedOperationException` — the class hierarchy is open, not
  enumerable), a self-derive `(derive x x)` throws (clj `AssertionError`), and
  `derive`/`underive` on a non-hierarchy map (`(derive {} :a :b)`,
  `(underive {} :a :b)`) throw (clj `NullPointerException` on the field
  dereference). Previously each silently built or returned a bogus hierarchy.
  cljw matches by throwing (the exception Kind differs — accepted divergence
  AD-007). The valid 2-arity global-hierarchy path is unaffected.

- **`(atom v :meta m)` / `ref` / `agent` reject a non-map `:meta`.** clj's
  `setup-reference` casts a `:meta` constructor option to `IPersistentMap`, so a
  number, set, or vector `:meta` throws `ClassCastException` — but cljw silently
  accepted it (e.g. `(meta (atom 1 :meta 5))` returned `5`). All three reference
  constructors now reject a non-nil, non-map `:meta` through one shared guard
  (`iref.requireMetaMap`).

- **`(contains? array i)` tests index validity instead of throwing.** A Java
  array is Indexed, so clj's `contains?` answers `true`/`false` for an integer
  key by bounds — but cljw raised `No implementation of method
  '-contains-key?' on protocol 'Associative' for type 'array'` for every key.
  It now matches: an integer key reports whether the index is in range. A
  non-integer key still raises (an array is not associative, so — unlike a
  vector's miss, which is `false` — clj does not treat it as merely absent).

- **`(empty x)` returns `nil` for a non-collection instead of throwing.** clj's
  `empty` answers `nil` for anything that is not an `IPersistentCollection` — a
  number, char, keyword, symbol, boolean, ratio, BigInt, or a Java array — but
  cljw raised `No implementation of method '-empty' on protocol
  'IPersistentCollection' for type 'Long'`. It now matches clj: every
  non-collection value yields `nil`. A `deftype`/`reify` that declares itself a
  collection still raises if it left `-empty` unwired — a missing impl there is a
  developer error, not a silent `nil`.

- **`(range …)` over Long bounds past ±2^47 no longer errors — a range spans
  the full Long domain.** cljw stores an integer past its ±2^47 inline window as
  a heap Long, and a recent fix taught `int?` to recognise those; that routed
  `(range (bit-shift-left 1 55) (+ 4 (bit-shift-left 1 55)))` to the compact-range
  fast path, whose guard accepted only inline integers — so it raised `-range:
  expected integer, got big_int` where clj yields the finite Long range.

  A compact range is now a full i64-domain value, like a JVM `LongRange`: it
  accepts heap-Long bounds, and every element it hands out — through `first`,
  `nth`, `reduce`, `count`, a chunked `map`/`seq` walk, or print — boxes a value
  past ±2^47 as a heap Long (exact, class `Long`), never a float. A range whose
  elements cross the ±2^47 boundary mid-sequence is exact throughout. Every
  projection of the range to a value now flows through one boxing point, so
  there is no path left that can still spill an element or the count to a float.

## [1.11.1] - 2026-08-25

### Added

- **`cljw.net/listen` — a cljw process can now SERVE, not only dial.**
  `cljw.net` exposed `connect` and nothing else, so a cljw program could reach
  out and never answer: no RPC endpoint, no socket server, no accepting
  anything. The `.listen`/`.accept` pair it needed has been in
  `src/app/nrepl.zig` the whole time (cljw runs an nREPL server); this lifts it
  to a Clojure-facing surface.

  ```clojure
  (let [srv  (cljw.net/listen "127.0.0.1" 0)   ; 0 = ask the OS
        port (.port srv)                        ; ...and find out what it gave
        sock (.accept srv)]                     ; blocks until a peer arrives
    (.read sock (byte-array 1024))
    (.close sock)
    (.close srv))
  ```

  `.accept` answers a socket built on the **same** descriptor `connect`
  produces, so `.read` / `.write` / `.close` gained no new arm — a new
  *producer* of an existing representation rather than a second representation
  every reader would have to tell apart.

  `.port` reports the BOUND port, which is the only thing that makes `(listen h
  0)` usable. `.close` is idempotent and closes the listener alone: sockets it
  already handed out stay open, matching a JVM `ServerSocket`.

  A hostname is rejected rather than resolved. You bind an interface this host
  already owns, so there is nothing to look up and a name is a caller mistake.

- **`cljw.net/connect-unix` and `cljw.net/listen-unix` — UNIX domain sockets.**
  A unix socket needs no port to allocate or collide on, and the filesystem
  already answers who may connect, which is why local RPC endpoints prefer one.

  ```clojure
  (let [srv  (cljw.net/listen-unix "/tmp/app.sock")
        sock (.accept srv)]
    (.read sock (byte-array 1024))
    (.close sock)
    (.close srv))
  ```

  `UnixAddress.listen` / `.connect` answer the **same** `Server` / `Stream`
  types the IP pair does, so these reuse both carriers, both descriptors, both
  method tables and both finalisers unchanged — a unix socket is a different
  *address*, not a different representation. `.accept` / `.read` / `.write` /
  `.close` are the same functions the TCP side uses.

  Two behaviours are deliberate, and pinned by the e2e because they can look
  like bugs. `.port` on a unix server answers **0** — a unix socket genuinely
  has no port, and 0 is honest where a fabricated value would not be. And a
  leftover socket file from a dead process is **not unlinked for you**: the
  path may still belong to a live server, and deleting another process's socket
  is the caller's decision, not the runtime's.

  The 108-byte path cap is the OS's rather than the filesystem's — easy to
  exceed with an ordinary temp path — so it is reported as a clear argument
  error instead of an opaque bind failure.

### Fixed

- **`assocEx` is wired on a `deftype`/`reify` `clojure.lang.IPersistentMap`
  section.** clj's `IPersistentMap` declares `assocEx` — assoc that throws when
  the key is already present — so a type implementing the interface faithfully
  declares it. cljw's remap table had no row for the name, and an unwired
  `clojure.lang.*` method is a LOAD-time raise, so one unrecognised name took
  down the entire type, and with it the namespace, and with it every namespace
  requiring it.

  Found against [replikativ/boring][boring]: `boring.data`'s `UnknownRecord`
  declares `assocEx` between `assoc` and `without`, and the namespace would not
  load at all. The declaring type's own body supplies the behaviour, so
  registering the method is all cljw owes it; `IPersistentMap` gains the
  matching `-assoc-ex` protocol method plus the identity remap row every
  member needs so a cljw-form `extend-type` section passes through unrewritten.

  `(.assocEx native-map k v)` stays deliberately unwired. There is no
  `clojure.core` fn with `assocEx`'s semantics, and mapping it to `assoc` would
  answer a *different question silently* — the failure class F-002 rejects. It
  therefore still raises, which is the honest answer until a caller justifies a
  real primitive.

[boring]: https://github.com/replikativ/boring

## [1.11.0] - 2026-08-22

### Added

- **cljw compiles and runs on wasm32-wasi** — `zig build -Dtarget=wasm32-wasi` produces a module that runs full Clojure under wasmtime, Chicory (in-JVM) and zwasm. The precise root set already covers the vm backend, so no GC rewrite was needed. (ADR-0193.)

- **A guest's linear memory is readable and writable from Clojure** —
  `(wasm/mem-size m)`, `(wasm/mem-read m :f64 offset n)` and
  `(wasm/mem-write! m :f64 offset data)`. `wasm/call` marshals scalars, which
  reaches every guest whose whole interface fits in numbers; the dominant
  convention for a *numeric* guest does not — it passes an array as a
  `(pointer, length)` pair into linear memory, so the host has to fill the
  buffer before the call and read it after. Until now `wasm/call` could pass
  the pointer and nothing could put anything at the other end of it.

  Element types are the nine wasm widths (`:i8 :u8 :i16 :u16 :i32 :u32 :i64
  :f32 :f64`), offsets are in bytes, encoding is little-endian (the wasm memory
  model), and unaligned access works — a `(ptr,len)` ABI hands the host
  whatever offset the guest's allocator produced. `:i64` round-trips exactly
  past the immediate-integer window rather than degrading to a float, and every
  bad offset, count or element is a catchable exception naming the fn and the
  element index, never a host panic. (ADR-0192.)

## [1.10.19] - 2026-08-22

### Performance

- **`(seq s)` over a string is now an O(1)-per-step byte-offset view**
  (the JVM `StringSeq` model), replacing the eager n-cell codepoint cons
  chain. The old path asked `codepointAt(s, i)` per element, restarting a
  UTF-8 walk from byte 0 each time — **O(n²)** overall (measured 89,910 ms
  for a 146,670-character string; downstream, bb-mcp paid ~79 s/boot asking
  `(seq value)` as a truthiness test on a large nREPL response). Now O(n):
  `first` decodes in place at the byte offset, `rest` advances by the width
  read, `count` is a single forward scan. A `StringSeq` is an ordinary seq of
  characters — `seq?`, `sequential?`, `=`/`hash` with the equal char list
  **and** char vector (incl. as a map key), UTF-8-correct `count`/`nth`.
  (O-060, D-179; `.string_seq` heap tag — a day-1 F-004 reservation, no slot
  spent.)

## [1.10.18] - 2026-08-22

### Performance

- **`subvec` is now an O(1) shared-structure view** (the JVM
  `APersistentVector$SubVector` model), replacing the eager `(into [] (take …
  (drop …)))` rebuild — the last catastrophic collection gap. Measured 2000
  slices on a 16,000-element vector: **9215 ms → 0.77 ms (~11,967×)**, now at
  parity with Clojure/JVM. A subvec is a first-class `IPersistentVector`
  (`vector?`, `=`/`hash`/`compare` with an equal vector, `nth`/`conj`/`assoc`/
  `pop`/`peek`/`seq`/`rseq`/`reduce`, metadata, nested-subvec flattening); its
  `conj`/`assoc`/`pop` share structure with the parent instead of copying.
  (O-059, D-583/D-044; new `.sub_vector` heap tag from the F-004 `box` slot.)

## [1.10.16] - 2026-08-21

### Fixed

- **clojure.core parity — comparators, `min`/`max`, `min-key`/`max-key`,
  `some-fn`/`every-pred`, `seqable?`** (from the clojure-test-suite drain):
  - `<` `>` `<=` `>=` `==` are `([x] true)` at 1-arity and no longer inspect the
    operand, so `(> "abc")` and `(== nil)` return `true` instead of raising a
    type error.
  - `min`/`max` propagate NaN like JVM Clojure: any NaN operand yields `##NaN`
    (`(max 1 ##NaN)` => `##NaN`) rather than dropping it.
  - `min-key`/`max-key` keep the later element on a tie and reproduce clj's
    IEEE-NaN behaviour.
  - `some-fn`/`every-pred` apply each predicate to each argument
    (`((some-fn even?) 1 2)` is `true`), where before they passed all arguments
    to one predicate and raised an arity error.
  - `seqable?` is now true for arrays.

## [1.10.14] - 2026-08-21

### Added

- **`cljw.test` — a source-path test runner.** `cljw -m cljw.test [dirs…]`
  discovers every `*_test.clj[c]` under the given roots (defaulting to the
  classpath, then `test/`), requires each namespace, runs it, and prints one
  totals line: `N namespaces, N tests, N assertions, N failures, N errors,
  N unloadable.` A namespace that throws while loading ran no assertions at
  all, so it is counted as **`:unloadable`** rather than folded into the error
  count — an assertion total that includes tests which never ran is a lie
  about coverage, and it is exactly the lie a compliance campaign cannot
  afford. The exit code is non-zero if anything failed, errored, **or** failed
  to load.

- **`java.class.path`** is answered by `System/getProperty` and appears in
  `System/getProperties`, joined from the runtime's load paths with the
  platform separator. `cljw.test` uses it to default its roots.

- **`clojure.test` gains the API that clj's `:test` model unlocks**:
  `test-ns`, `test-vars`, `test-all-vars`, `test-var`, `run-test`,
  `run-test-var`, `with-test`, `set-test`, `deftest-`, `successful?`,
  `*load-tests*`, `assert-predicate`, `assert-any`,
  `get-possibly-unbound-var`, plus `assert-expr` methods for `instance?` and
  `:always-fail`. `run-all-tests` now walks `all-ns` and accepts a regex.

### Fixed

- **`clojure.edn/read-string` and `clojure.core/read-string` now differ on
  empty input, matching clj.** `clojure.edn/read-string`'s 1-arity defaults
  `{:eof nil}`, so empty / whitespace-only / comment-only input returns `nil`
  (its docstring: "Returns nil when s is nil or empty"); `clojure.core/read-string`
  throws `EOF while reading` on the same input. cljw previously threw for both —
  the shared body had been reasoned about from `core`'s behaviour and never run
  against `edn`. An explicit `:eof` opt still overrides for either reader.

- **`*print-level*` was off by one for every record.** The depth bookkeeping
  keyed off `Value.tag()`, and `.typed_instance` is not a collection tag — but
  a record and a deftype declaring `clojure.lang.IPersistentMap` both render as
  maps. `(binding [*print-level* 1] (pr-str (R. {:x 1})))` gave
  `#user.R{:a {:x 1}}` where clj gives `#user.R{:a #}`, and at the cut a record
  now renders `#user.R#` — the tag prints outside the cut and the map body
  inside it, as clj does. A deftype carries no tag, so it cuts to `#` whole.

- **A `print-method` override rendered against the PREVIOUS print's limits.**
  `printConsult` snapshotted `*print-length*` / `*print-level*` / `*print-meta*`
  / `*print-namespace-maps*` / `*print-readably*` only on the path where no
  override fired. So `(binding [*print-length* 2] (pr-str (Box. [1 2 3 4 5])))`
  printed `Box<[1 2 3 4 5]>` instead of clj's `Box<[1 2 ...]>` — and because the
  snapshot is thread-local, a print's output depended on what had been printed
  before it in the process. The same expression could render truncated or
  untruncated according to print history, so a test could pass alone and fail in
  a suite. Only a value whose own type carried the override was affected; the
  same value nested one level deeper was already correct.

- **An IPersistentMap-declaring deftype inside a `print-method` override**
  rendered `#Pm[{:a 1}]` instead of clj's `{:a 1}`, because the override path
  never armed the context the map-style render needs.

- **A macro that `throw`s while expanding now surfaces the exception it
  threw** — catchable, with its message, its `ex-data` and its host class
  intact. It used to become `Internal error: macro callFn raised foreign
  error`, because `narrowCallFnError` folded `error.ThrownValue` into
  `InternalError`. Argument validation in a macro — what `clojure.core`'s own
  `assert-args` does, and what every macro rejecting a malformed binding
  vector does — could therefore not tell its caller what was wrong.

- **`clojure.test` reported something other than what ran**, in three ways
  that all read as green (ADR-0191):

  - `(run-tests *ns*)` — the call clj's own 0-arity makes — printed
    `Ran 0 tests, 0 failures` because the registry was keyed by namespace
    *symbol* and a `Namespace` object matched nothing. `run-tests` /
    `test-ns` / `test-all-vars` now accept a symbol, a string or a
    `Namespace`, and an unknown namespace raises instead of passing.
  - Re-evaluating a `deftest` (any reload) registered the var a second time,
    so one test counted as two. Registration is idempotent now.
  - `(are [x y] (= x y) 1 1 2)` silently dropped the trailing partial group
    and passed; it now throws `IllegalArgumentException`, as clj does.

- **`use-fixtures` replaces rather than appends**, and stores into the
  namespace's own metadata where clj keeps it — so reloading a namespace no
  longer runs its fixtures once more per reload.

- **`report`'s `:default` method prints an unrecognised event** instead of
  swallowing it, which is what makes the explicit no-op methods for the
  per-var events load-bearing rather than decorative.

### Internal

- **CI's Zig build cache now actually caches.** The cache key was
  `hashFiles('build.zig.zon', 'build.zig')` — files that change a few times a
  year — so it hit on nearly every run, and `actions/cache` only *writes* an
  entry when its key *misses*. The restored `.zig-cache` was frozen at whatever
  the first run with that `build.zig` produced; every run since rebuilt
  everything that had changed after that snapshot and discarded the result,
  while the step reported a cache hit. Measured on the Linux leg:
  `zig_build_test_vm` 375 s and `zig_build_test_tree_walk` 371 s — 50% of a
  1491 s gate — against ~5 s each warm. The key now carries the run id with
  prefix `restore-keys`, and restore/save are split with `if: always()` so a
  **failed** run still saves its build products, which is precisely when the
  next run needs them. `scripts/prune_zig_cache.sh` bounds the saved tree so
  "always save" cannot become unbounded growth.

- **`scripts/run_gate.sh` no longer kills healthy gates.** Its timeout defaulted
  to 900 s, sized against a "~350 s serial gate"; the suite has since grown to
  1009 s (macOS) / 1491 s (Linux) cold, so the default could not complete a full
  gate on any host. The kill presented as a log that simply stopped — no summary
  line, nothing to distinguish it from a pass, which is the failure mode the
  script's own header warns about. Default is now 2700 s, and a timeout prints
  an explicit "KILLED, not failed" verdict instead of exiting quietly.

### Changed

- **`clojure.test` adopts clj's var model** (ADR-0191): a test's body lives in
  the var's `:test` metadata and the var's value is a thunk routing through
  `test-var`. `*test-registry*` is demoted to a pure definition-order index.
  This is what makes cljw legible to any runner that enumerates `ns-interns`
  filtering on `:test`, and what makes `(alter-meta! #'f assoc :test …)` work.

- **The printer's VM re-entry is an explicit parameter.** `printValue` took
  `(w, v)` — the signature of something that cannot evaluate — while two
  file-private thread-locals let it call arbitrary user Clojure and dispatch
  protocols. Both are gone, replaced by a `?Ports` threaded through the
  recursion: `null` at a caller that cannot evaluate, rt/env at one that can.
  The three print fixes above were all one shape — state armed at one entry
  point and read from another — which a parameter makes impossible.

- **Printing no longer realizes what `*print-level*` will cut**, and no longer
  rebuilds a vector that holds nothing lazy. A depth-18 tree at
  `*print-level* 1` renders in 0.10 ms where it took 6668 ms (50 prints); a
  20 000-element vector printed 200 times takes 189 ms where it took 1167 ms.
  No output changes.

## [1.10.6] - 2026-08-14

### Internal

- **The release bump also stamps this file.** `preflight` renames
  `## [Unreleased]` to `## [X.Y.Z] - date` and opens a fresh one in the SAME
  `chore(release)` commit that rewrites `build.zig.zon`, so the changelog and
  the tag are written together and cannot drift
  (`.github/stamp_changelog.py`).

  A version whose `[Unreleased]` body is **empty is not stamped**: patches now
  cut themselves on every source push, and a release nobody wrote up must not
  mint an empty version heading. CHANGELOG.md is deliberately absent from the
  workflow's relevance paths for the same reason build.zig.zon is — the bump
  commit touches both, and counting them would make each release mint the next.

  `1.10.3`–`1.10.5` were stamped by hand: they shipped between the arrival of
  automatic patch releases and this, so their entries had accumulated under a
  single `[Unreleased]` heading with no version to attach to.

## [1.10.5] - 2026-08-14

### Fixed

- **Dropped a dead `std` import from `Future.zig`.** Lint-only; the module's
  behaviour is unchanged.

## [1.10.4] - 2026-08-14

### Changed

- **`(seq v)` / `(rest v)` / `(next v)` on a vector are now a VIEW, not a copy.**
  They used to build an eager `PersistentList` — n cell allocations and n trie
  descents per call. They now return an `ArraySeq` holding `(vector, index)`,
  which is what Clojure does (`PersistentVector$ChunkedSeq`). All three drop
  from O(n) to O(1): measured over a 16000-element vector, `seq` 2123 → 0.36 ms,
  `rest` 2253 → 0.39 ms, `next` 2164 → 0.38 ms per 2000 ops — from 2184-3549×
  slower than JVM Clojure 1.12.4 to 1.7-2.6× faster. `nth` on such a seq is now
  O(1) too, where clj still walks. See `O-058` in `.dev/optimizations.md`.

  Everything observable is unchanged — it prints as a seq, is `=` to the list
  and the vector with the same elements, hashes with them, and works as a map
  key — with ONE exception: **`(class (seq [1 2 3]))` now answers `ArraySeq`
  where it used to answer `PersistentList`.** Neither matches the JVM's
  `PersistentVector$ChunkedSeq`; code that branches on that class name was
  already non-portable, and `seq?` / `sequential?` / `coll?` / `counted?` are
  unaffected.

  This closes item 2 of `.dev/bench/README.md`'s ranked list — which that file
  had wrongly recorded as blocked on item 1 (`SubVector`). See the correction
  there: `next` of a seq is a seq, so the vector-seq needed `(vector, index)`
  and never needed a smaller vector. `subvec` remains eager (D-044).

## [1.10.3] - 2026-08-14

### Added

- **`java.util.concurrent.Future`'s method names on cljw's own futures.** `.get`
  (`[]` / `[timeout unit]`), `.isDone`, `.isCancelled` and `.cancel`
  (`[]` / `[mayInterruptIfRunning]`) now resolve on the value `(future …)`
  returns — which already answered `Future` to `class` and already had every
  semantic behind `deref` / `realized?` / `future-cancel` / `future-cancelled?`.
  Each method delegates to that existing primitive, so `.get` and `@` cannot
  disagree: a cancelled future still throws `CancellationException` and a failed
  one still re-raises the worker's marshalled error (ADR-0120) rather than a
  second set of answers invented for the Java spelling.

  The timed arity is the one deliberate departure from cljw's own `deref`:
  `(.get f timeout unit)` **throws `java.util.concurrent.TimeoutException`**
  where the 3-arity `deref` returns a caller-supplied default, because code that
  catches TimeoutException to decide whether to cancel would read a returned
  default as success. The eval budget still bounds the wait, and a future still
  pending at the budget's deadline reports the budget instead.

  `Future` also joins the reify-able host interfaces (both the qualified and the
  bare post-`:import` spelling), for libraries that synthesise an
  already-completed Future rather than minting a worker.

  `mayInterruptIfRunning` is accepted and ignored (AD-065): cljw's cancellation
  is cooperative, so there is no queue-vs-running distinction to honour.

- **`java.util.concurrent.RejectedExecutionException` is a known exception
  type**, so `(catch RejectedExecutionException …)` compiles. A `RuntimeException`
  like on the JVM. Caught-but-never-thrown for now, joining `InterruptedException`
  / `TimeoutException` / `ExecutionException` in that family — cljw has no pool
  that rejects a submission yet.

  Both found by driving [hive-weave](https://github.com/hive-agi/hive-weave)
  through cljw: `hive-weave.pool` — a bounded pool with caller-runs fallback,
  binding-conveying `submit!` and a synthetic Future for work that ran on the
  caller thread — now loads on it.

- **`java.util.concurrent.Semaphore`.** Permits live in one atomic counter and
  move by CAS: `<init>` (`n` / `n fair?`), `.acquire` (`[n]`), `.tryAcquire`
  (`[n]`, `[timeout unit]`, `[n timeout unit]`), `.release` (`[n]`),
  `.availablePermits`, `.drainPermits`, `.getQueueLength`, `.hasQueuedThreads`,
  `.isFair`. A parked caller polls through the budgeted sleep `Thread/sleep`
  owns, so `future-cancel` and the eval budget cut the wait short instead of
  pinning a worker for the whole timeout. Fairness is recorded but does not
  order acquisition (AD-061). Found by driving
  [hive-weave](https://github.com/hive-agi/hive-weave)'s admission gates
  through cljw: `hive-weave.gate` and `hive-weave.budget` — permit gating,
  cost-based budget admission, saturation timeouts and stats — now run on it.

- **`java.util.concurrent.atomic.{AtomicLong,AtomicInteger,AtomicBoolean}`.**
  One CAS-moved word each: `<init>` (`[v]`), `.get`, `.set`, `.lazySet`,
  `.getAndSet`, `.compareAndSet` / `.weakCompareAndSet`, plus the numeric
  `.incrementAndGet`, `.decrementAndGet`, `.getAndIncrement`,
  `.getAndDecrement`, `.addAndGet`, `.getAndAdd`, `.longValue` / `.intValue`.
  Exact under cljw's real OS threads — four threads racing 500 increments
  apiece land 2000, not fewer. AtomicInteger does not truncate to 32 bits
  (AD-062).

- **`java.util.concurrent.TimeoutException` is constructible.** `catch` already
  resolved the class (`host_class.zig` carries the FQCN mapping and the
  `TimeoutException < Exception` edge); the surface adds `(TimeoutException.)`
  / `(TimeoutException. msg)`, which is what a library needs to raise one.

- **`java.lang.Runtime` reports memory.** `.totalMemory`, `.freeMemory` and
  `.maxMemory` answer from cljw's own mark-sweep accounting and from the
  `CLJW_EVAL_MAX_HEAP_MB` ceiling (ADR-0125) rather than from a fabricated
  constant, so a heap-pressure monitor either reads real numbers or correctly
  reads "no ceiling" (AD-063).

- **`java.util.concurrent.LinkedBlockingQueue`.** A bounded FIFO backed by a
  cljw vector plus a head index: `<init>` (`[capacity]`, unbounded without),
  `.offer` (`[x]`, `[x timeout unit]`), `.put`, `.poll` (`[]`,
  `[timeout unit]`), `.take`, `.peek`, `.size`, `.isEmpty`,
  `.remainingCapacity`, `.remove` (`[]`, `[x]`), `.contains`, `.clear`,
  `.toArray`, `.drainTo`. The head index is what keeps it a queue —
  `vector.subvec` is an O(n) eager copy (D-044), so dequeuing by rebuilding
  from index 1 would make draining a work queue quadratic; the dead prefix is
  compacted only once it dominates the vector, which amortises to O(1). Blocking
  waits poll through the budgeted sleep `Thread/sleep` owns, and the per-instance
  spin lock is never held across one. `.drainTo` returns the drained elements
  rather than filling a mutable target cljw does not have (AD-064).

- **`ThreadFactory`, `Callable` and `Runnable` are reify-able.**
  `(reify java.util.concurrent.ThreadFactory (newThread [_ r] …))` — and the
  bare spelling after `:import` — now loads and dispatches, so a library can
  hand a pool its own worker-minting policy. They join the host-interface
  closed set (`data/host_interfaces.yaml`, ADR-0102) rather than becoming
  native classes, because `reify` accepts only a protocol Var or a marker name
  and rejects a class value outright.

### Fixed

- **Host surfaces returning a large integer no longer hand back a Double.**
  `Value.initInteger` silently converts an argument outside the NaN-boxed i48
  range to an `f64`; an exact Long past that range must be heap-boxed through
  `big_int.allocFromI64(rt, i, .long)`. Caught on `(.maxMemory
  (Runtime/getRuntime))`, which returned `9.223372036854776E18` — a value that
  fails `(= … Long/MAX_VALUE)` and poisons integer arithmetic downstream.

## [1.10.2] - 2026-08-12

The fork's first runtime changes. Nearly all were found by driving
[malli](https://github.com/metosin/malli) through the
`test/conformance/verified_projects/` probe loop — malli is the first schema
library on the ladder, and the blockers it surfaced are general capabilities,
not malli accommodations (F-013). The last two entries under Added come from the
next rung, hive-contracts.

### Fixed

- **Macro expansion no longer drops symbol metadata.** `formToValue` attaches a
  symbol's `^meta` to the symbol Value (ADR-0110), but `valueToForm` rebuilt only
  `{ns, name}` — so every macro-produced form silently shed type hints,
  `^:private`, `^:const`, `^:dynamic`, and the `^:volatile-mutable` /
  `^:unsynchronized-mutable` deftype field markers. The visible symptom was a
  `deftype` whose method `set!`s a mutable field failing to resolve that field
  when, and only when, a macro emitted the form:

  ```clojure
  (defmacro mm [x] x)
  (mm (deftype E [^:volatile-mutable c]
        clojure.lang.IDeref (deref [_this] (do (set! c 9) c))))
  ;; was: Name error: Unable to resolve symbol: 'c'
  ```

  Writing the identical `deftype` literally worked, which is what isolated the
  fault to the Value↔Form round trip rather than to `deftype` or to `set!`.

### Added

- **`(instance? my.ns.MyProtocol x)`** — a protocol named by the interface name
  `defprotocol` generates on the JVM now resolves, including the package-segment
  demunge, so `my_ns.core.Q` finds the protocol in `my-ns.core`. Bare `P` and
  `alias/P` already worked; only the dotted form was unreachable.
- **`monitor-enter` / `monitor-exit`** in `clojure.core` — the two halves
  `locking` was already built from, on the same object monitor.
- **`clojure.lang.LazilyPersistentVector`** — `createOwning` / `create`.
- **`clojure.lang.PersistentArrayMap`** — `createWithCheck` (throws
  `IllegalArgumentException` on a duplicate key) / `create`.
- **`clojure.lang.Murmur3/hashLong`** and **`/hashInt`** — the implementations
  already existed in `hash.zig`; only the surface entries were missing.
- **`java.util.ArrayDeque`** — `push` / `pop` / `peek` / `poll` / `addFirst` /
  `addLast` / `removeFirst` / `removeLast` / `peekFirst` / `peekLast` / `size` /
  `isEmpty` / `clear`, plus `seq` and `count`.
- **`java.util.concurrent.TimeUnit`** — the seven constants as host-enum
  singletons (ADR-0161 registry), plus `.name` / `.toString` / `.toMillis` /
  `.toNanos`.
- **`java.lang.reflect.Array`** — `newInstance` / `getLength`. AD-031: the
  component-type argument is ignored, since cljw arrays are Object[] (ADR-0105).
- **`java.util.HashMap`** — the `(int, float)` sizing constructor and `.putAll`.
- **`java.util.AbstractList` / `java.util.Vector`** resolve as opaque classes
  (ADR-0109), so a library branching on them loads with that branch correctly
  dead. `java.util.ArrayList` declares `AbstractList` among its host supertypes,
  so `instance?` stays JVM-faithful for the one cljw does have values of.
- **`InterruptedException`, `TimeoutException`, `ExecutionException`** are now
  known catch classes. cljw has no interrupts and never throws them, so the
  clauses are dead by construction — but portable code guarding a bounded wait
  now loads instead of failing analysis.

The last two came from the next rung of the same loop,
[hive-contracts](https://gitea.hive-mcp.com). Both are reached through
`clojure.tools.reader`, which `taoensso.encore` — and so `timbre` — requires.

- **`clojure.lang.PersistentList/create`** — a list of a collection's elements,
  in order. `clojure.tools.reader.edn` calls it to build every list it reads.
- **`clojure.lang.LineNumberingPushbackReader`** resolves as an opaque class
  (ADR-0109), under its bare name as well as its FQCN since clj auto-imports
  `clojure.lang.*`. cljw readers are not instances of it, so `instance?` is
  uniformly false and `extend`ing it registers a branch nothing dispatches to —
  which is what `tools.reader` does with it.

### Internal

- `data/core_surface_extras.txt` regenerated, 104 → 106 names: `monitor-enter`
  and `monitor-exit` are a deliberate addition to clojure.core's extra public
  surface (AD-057). No name was removed.
- `scripts/check_core_surface.sh` pins `LC_ALL=C`. `sort`/`comm` were collating
  under the caller's locale, so the ledger regenerated to a different order on
  different machines — 16 lines of reordering noise around 2 real ones, in the
  one diff the gate exists to keep readable.
- `test/e2e/phase15_ns_import.sh` uses `java.util.ServiceLoader` as its
  unimplemented-class fixture. It had used `ArrayDeque`, which this release
  implements — the same way it previously used HashSet/TreeSet before D-431.
  `ServiceLoader` is classloader-driven, so a JVM-free runtime will not
  implement it and the fixture cannot go stale again.
- `test/e2e/phase16_gc_torture.sh` sets and clears environment variables with
  bash builtins instead of `env`, which is hijackable by a `~/.local/bin/env`
  on PATH.
- Two deprecated `std.mem` aliases replaced by their current names
  (`indexOfScalar` → `findScalar`, `indexOfAny` → `findAny`). Both are `pub
  const` aliases in 0.16 std, so the rename is behaviour-identical; the linter
  that rejects them runs only on the macOS gate leg, which is why they were
  reachable at all.
- The printer gains Layer 6/7 coverage (ADR-0186): a property asserting every
  `printFloat` output parses back to the same f64 — bit equality, so `0.0` and
  `-0.0` stay distinct — and golden snapshots for the HAMT print path above both
  promotion boundaries, for truncation at `*print-length*` 0, and for lazy seqs
  nested inside collections. The first mutation sweep of `print.zig` scored
  36.4%; these pin three of the survivors it named.
- `scripts/mutation/run.sh` takes `--oracle`. The kill oracle was hardcoded to
  `zig build test`, so a mutation in a rendering path could never be killed by
  the golden layer and every printing line scored as unconstrained. `unit`
  remains the default; `unit+golden` also renders the Layer 6 cases.

### Changed

- **The embedded Wasm engine is fetched from `zwasm/zwasm`.** zwasm moved out of
  the `clojurewasm` org into its own, where it continues under separate
  maintainership. `build.zig.zon` now names that location directly instead of
  relying on GitHub's transfer redirect, which is only an alias until something
  else claims the vacated name. The pin itself is unchanged — same tag (v2.5.0),
  same commit, same content hash. Merged from upstream, which made the same
  change in its own final release.
- **Release and CI workflows survive a re-run.** Both clear the Zig unpack
  target before `tar -x`, so a re-run cannot die on "Cannot open: File exists",
  and `release.yml`'s `gh release view || gh release create` race across the
  matrix legs is fixed: a failed create is accepted iff the release exists
  afterwards. Merged from upstream.

## [1.10.1] - 2026-08-12

**The first release of the maintained fork.** It carries no runtime change —
the binary is v1.10.0's, rebuilt — and exists to prove the fork's own release
path end to end: tag on `BuddhiLW/ClojureWasm`, artifacts built by this
repository's `release.yml`, and a `buddhilw/tap` formula pointing at them. A
release cut against a distribution path nobody has exercised is a guess; this
one makes the guess cheap to check.

### Changed

- **Maintenance moved to a fork.** Upstream
  [clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm)
  stopped at v1.10.0, its final release, and invited forks under EPL-2.0.
  Development continues in
  [BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm) from that
  exact tree — same gate, same ADR record, same release workflow. Nothing in
  the runtime changed. What moved: Issues and Pull Requests are open here
  (upstream disabled both, so contributions arrived as branches to
  cherry-pick), the Homebrew tap is now `buddhilw/tap`
  (`brew install buddhilw/tap/cljw`), and README / CONTRIBUTING / SECURITY /
  issue templates point at this repository. The `1.x` line continues from
  v1.10.0.

> **On the version number.** Upstream `clojurewasm/ClojureWasm` also tagged a
> `v1.10.1`, on the same day, from its own tree — its last release, carrying the
> zwasm repoint and its wind-down documentation. That tag names commit
> `8fa46d97`; this project's `v1.10.1` names `50b85214`, and it is the one
> `brew install buddhilw/tap/cljw` resolves. Since upstream's history is now
> merged here, both commits are reachable from this repository and the *name*
> `v1.10.1` no longer identifies one of them. Nothing after v1.10.1 collides:
> upstream cut no further releases, so this project's `1.x` continues
> unambiguously from v1.10.2.


## [1.10.0] - 2026-08-12

**The final release.** ClojureWasm is no longer maintained — a from-scratch
Clojure runtime turned out to be more than one person can sustain, and this
release exists so it stops at a working, fully-tested state rather than
mid-stream. The code stays up under EPL-2.0; fork it and build on it, no
permission needed. See the README for the full notice.

Everything here is a fix, and three of the four were found by @BuddhiLW,
who reported them with diagnoses and working branches — thank you. Each
one's *class* was then swept, which is where the rest of the fixes came
from. MINOR rather than PATCH because `repl` and `nrepl` gain a `-cp` /
`-A:alias` surface, and `cljw repl` now rejects unknown arguments it used
to ignore.

### Fixed

- **A top-level `(do …)` that requires before it uses now works in every
  entry point.** `(do (require '[clojure.string :as s]) (s/upper-case
  "ok"))` returned `"OK"` from `cljw -e` but raised `No namespace: 's'`
  over nREPL and in `cljw repl`, and failed to compile under `cljw build`:
  the top-level-`do` unroll, which analyses and evaluates each child in
  sequence so an earlier `require` or `defmacro` is visible to a later
  child, had only ever been wired into the script path. Reported,
  diagnosed and fixed for the REPL engine by @BuddhiLW (Discussion #14;
  commit cherry-picked with authorship preserved); the `cljw build` half
  was found by auditing the other callers. A new differential oracle
  (`test/e2e/entrypoint_eval_parity.sh`) now runs each program through
  `-e`, a script file, stdin, `repl`, `nrepl`, and `build`+run and
  requires all six to agree, so this class of entry-point divergence
  fails the gate instead of reaching users.

- **A set literal of 9+ elements no longer crashes macroexpansion**
  (segfault / index-out-of-bounds / bogus "cannot be re-analysed" —
  three faces of one misread). The analyzer decoded the set's backing
  map as if it were always array-backed; past the 8-element promotion
  boundary it read hash-map fields as array fields. Reported with a
  model bisection and fixed by @BuddhiLW (Discussion #12; commit
  cherry-picked with authorship preserved).
- **The same representation misread was audited tree-wide and three more
  live instances fixed**, all at the same 8→9 boundary: multimethod
  hierarchy (`derive`/`isa?`) dispatch silently vanished at the 9th
  `defmethod`; `cljw.http.client` rejected a 9-entry `:headers` map;
  `cljw.http.server` dropped all custom response headers past 8 entries.
  A structured-error-log context map of 9+ entries was also silently
  omitted from the EDN event. A new per-commit gate
  (`scripts/check_repr_decode.sh`) forbids the whole class: collection
  backing representations are now private to `src/runtime/collection/`.
- **`cljw nrepl` resolves the filesystem classpath** — it previously
  rejected `-cp`, ignored `$CLJW_PATH`, and never installed the
  filesystem require chain, so an editor session could not `require` a
  single namespace from the project it was started in. It now takes
  `[-cp <dirs>] [-A:alias…]` alongside `--port`, exactly like every
  other entry point. Diagnosed and fixed by @BuddhiLW (Discussion #13;
  commit cherry-picked with authorship preserved).
- **`cljw repl` no longer silently ignores trailing arguments** — it
  takes the same `[-cp <dirs>] [-A:alias…]` surface and rejects unknown
  args (`cljw repl -cp src` used to drop the `-cp` without a
  diagnostic). A new per-commit gate
  (`scripts/check_entrypoint_surface.sh`) requires every CLI entry point
  to be classified and reach the shared classpath resolution, so a
  future subcommand cannot repeat the nREPL omission.

### Changed

- The embedded Wasm runtime is pinned to **zwasm v2.5.0** (was v2.4.1),
  which brings full WASI 0.3 coverage and completes `libzwasm.a`'s C-API
  exports. Neither reaches cljw's embedding surface — cljw drives
  Engine/Module/Instance through Zig on the JIT-default `.auto` engine —
  so this lands the final release on zwasm's current stable rather than
  changing behaviour. zwasm continues under separate maintainership.

## [1.9.0] - 2026-08-05

**Upgrade if you run untrusted code under `cljw.eval/with-budget`, parse
untrusted JSON/EDN, use long-running programs (the GC got a lot faster on
them), or want named groups / lookbehind / `\A \z \Z` / class algebra in
regexes.** MINOR rather than PATCH because behaviour changes: code that
relied on a blocking call outliving its budget now raises.

### Changed

- **The eval budget's wall-clock deadline now bounds blocking calls — all of
  them.** `(Thread/sleep 25000)` under a 3 s deadline used to return normally
  after 25 s; `@(promise)` under a deadline used to park forever. Every
  blocking primitive (`future`/`promise` deref, timed deref, `Thread/sleep`,
  `await`) now waits on a latch bounded by `min(caller timeout, budget
  deadline)`.
- **The budget follows the work, not the thread.** A `Thread.`, `future` or
  agent action spawned inside a `with-budget` extent inherits the budget —
  same absolute deadline, same shared (atomic) step ceiling — and keeps it
  even if it outlives the extent. A spawned 60 s sleep under a 500 ms
  deadline used to hold the process for the full 60 s; it now dies at the
  deadline. A compute loop cannot escape the step ceiling by moving onto a
  spawned thread.
- **A rejection caused by bad DATA is now catchable.** Malformed JSON/EDN
  input, wrong-typed arguments (`clojure.string/replace`, `deliver`, walk
  callbacks, `*out*` bindings), malformed form shapes under `eval` /
  `read-string` (libspecs, destructuring, `ns` directives, reader
  conditionals) and malformed regex patterns all raise catchable errors, as
  JVM Clojure does — ~60 sites reclassified, each verified against the
  oracle. Genuinely unsupported features stay deliberately uncatchable.
  Messages improve with it: "deliver: expected a promise, got integer"
  instead of "… is not supported in ClojureWasm".

### Added

- **Regex: named groups** `(?<name>e)` (with `(.group m "name")`),
  **lookbehind** `(?<=)` / `(?<!)`, **`\A` `\z` `\Z` anchors**, **nested
  character-class unions** `[a[b]]` and **`&&` intersection**
  (`[a-z&&[^m-p]]`), and empty alternatives/groups (`()`, `a|`).
  Backreferences are declined by design — the matcher guarantees linear-time
  matching (the RE2 posture), and a backreference would force backtracking.
- **Multi-dimensional `aget` / `aset`** and the 8 typed `aset-*` multidim
  arms: `(aget a i j)`, `(aset a i j v)` on nested arrays, exactly clj's
  variadic recursion.

### Fixed

- **Long-running programs stopped paying a 2-4x GC tax.** The collection
  trigger is steered by the measured GC time share (the same control variable
  SubstrateVM sizes its heap with), and live-set accounting now counts what
  an object owns (string payloads, array elements, bignum limbs) instead of
  only its 32-byte record. A breadth-first search went 58.9 s → 17.7 s
  (1624 → 114 collections); a 200k-string workload went 263 → 55 collections.
  Short scripts and benchmarks are unchanged.
- **`@(future (Thread/sleep 2000))` ran 17% long** (2321-2358 ms) with no
  budget armed at all — the cancel poll sliced every worker sleep. Waits are
  latch-based now: 2000-2001 ms, and `future-cancel` wakes a sleeping worker
  in 0 ms instead of up to 20 ms.
- **`(Thread/sleep <huge long>)` aborted the process** with an integer
  overflow; it now sleeps, as clj does.

## [1.8.0] - 2026-08-04

**Upgrade if you use Wasm components, or if you use `doc` / `find-doc`.**
A component with more than one export could not be loaded at all, and `doc` on
most of `clojure.core` printed nothing.

### Added

- **`clojure.core.reducers`.** The full sequential surface — `r/map`,
  `r/filter`, `r/remove`, `r/mapcat`, `r/flatten`, `r/take`, `r/take-while`,
  `r/drop`, `r/reduce`, `r/fold`, `r/foldcat`, `r/cat`, `r/monoid`,
  `r/append!` — with the curried one-arity forms. 31 of 32 probed expressions
  are byte-identical to JVM Clojure; the one difference is set print order.
  `fold` computes the same value as upstream's but never in parallel: there is
  no ForkJoinPool here, so it takes the same single-reduce arm upstream itself
  takes for lists, ranges and sets. Its docstring says so.
- **`wasm/run` takes `:max-output-bytes` and `:timeout-ms`**, alongside the
  existing `:fuel` and `:max-memory-pages`. Both default to finite values
  (16 MiB per captured stream, 60 s); `0` or a negative value opts out.

### Fixed

- **A Wasm component with two or more exports failed to load.** Every fixture
  in this project and in zwasm exported exactly one function, so
  `(:require ["x.wasm" :as x])` — the headline feature — had only ever been
  exercised on single-function components. Fixed in zwasm v2.4.1, which this
  release pins.
- **`wasm/run` could be made to exhaust host memory.** It buffered the guest's
  stdout and stderr without limit, and the fuel budget does not bound that:
  fuel counts instructions, and how many bytes an instruction writes is the
  guest's choice. Measured, a guest could force ~64 GB before its fuel ran
  out. Also had no wall-clock bound — the same guest could run for roughly 18
  hours inside the default fuel budget.
- **A resource handle from a one-shot `wasm/component-invoke` was already
  invalid when you received it**, because the component was torn down before
  the call returned. Handle numbers are per-instance table indices starting at
  1, so passing it on could silently operate on a *different* resource. The
  component now lives as long as the handle does, and a handle is bound to the
  component that minted it.
- **`result` and `variant` could not be passed INTO a component.** They lifted
  out correctly, so the round-trip the mapping table describes was one-way.
- **`(doc reduce)` printed nothing** — and so did `assoc`, `conj`, `first`,
  `apply`, `=` and 320 others. The generated metadata table covered 246 of 685
  `clojure.core` publics and none of the ~290 implemented as native
  primitives, so `find-doc` and `apropos` were searching a third of core while
  answering as though they had searched all of it. Now 572 of 684.
- **`(clojure.set/intersection)` returned `nil`** where Clojure throws
  `ArityException`, and no var in `clojure.set` reported `:arglists`.

### Changed

- **`clojure.pprint` no longer publishes 49 internal formatter helpers**
  (`cl-tens`, `cl-roman`, `cl-under-1000`, …). Upstream keeps them private;
  they were public here only because they were written as `defn`. `cl-format`
  and the other six documented names are unaffected. Same for five
  `clojure.data` internals and three contrib parser implementation details.
- **`clojure.math` gained docstrings**, written for this runtime rather than
  imported — upstream's all end in a `java.lang.Math` Javadoc URL.

## [1.7.0] - 2026-08-04

**Upgrade if you load Wasm components.** An untrusted component could kill the
host process, and `result` errors were reaching you as generic Wasm traps with
the error value discarded.

### Fixed

- **An untrusted Wasm component could kill the host process.** The component
  marshaller used bare integer casts, which in the shipped ReleaseSafe build
  are process-killing safety panics rather than catchable errors. Two paths
  were reachable: lowering an out-of-range argument (`(c/f 300)` against a WIT
  `u8`), and — worse, because the data is the guest's — lifting a `u64` above
  `i64`'s maximum. Both now go through the same range check the core-module
  `wasm/call` surface has always used. A `u64` beyond `i64` and an `s64`
  beyond 48 bits now lift exactly via BigInt instead of panicking or silently
  becoming a lossy float.

### Changed

- **`result` and `variant` lift as tagged vectors.** `result` is now
  `[:ok v]` / `[:err e]` and `variant` is `[:case-name payload]`, with the
  payload slot omitted when the arm carries none — one destructuring idiom for
  every WIT sum type. This replaces an `err`→throw mapping that **discarded the
  error value**: the old path raised a generic Wasm *trap*, so a component
  returning `err("not found")` reached you as "WebAssembly module trapped" with
  the message gone. Throwing also had no meaning off the return position — a
  `result` nested in a `list` or `record` aborted the whole conversion.
  (ADR-0135 amendment 2.)

### Added

- **`clojure.core/*file*`** — the source being evaluated, matching JVM Clojure:
  the script path when a file runs, and `"NO_SOURCE_PATH"` otherwise. Still
  `^:dynamic`, so tooling can rebind it.

## [1.6.0] - 2026-08-04

**Upgrade if you use threads, futures, promises, or `wasm/run`.** This
release carries four fixes for ways cljw could hang or abort, two of them
outstanding since 1.5.1 (2026-07-17).

### Fixed

- **A live worker at process exit could abort (glibc `abort`).** A
  `future` / `promise` whose worker was still running while the runtime tore
  down could crash the process instead of exiting. `exitBarrier` plus
  deinit-chokepoint guards make a live worker force a daemon-style hard exit
  rather than a teardown under its own feet. Measured: 6 failures in 32 runs
  before, 0 in 96 after. (ADR-0176, AD-056)
- **Thread registration was not a GC safepoint (SIGABRT on x86_64 Linux).**
  The window between spawning a worker and registering it with the collector
  was not a safepoint, so a collection landing in that window could abort.
  Registration is now a safepoint, and the `TooManyThreads`
  run-unregistered fallthrough is closed. (ADR-0175)
- **`(wasm/run …)` ran guests unmetered — an infinite loop in a guest hung
  the host forever.** `wasm/load` has always defaulted to a finite fuel and
  memory budget; `wasm/run` passed no budget at all, so the two sibling
  surfaces had opposite postures. `wasm/run` now takes the same finite
  default. Measured: a spinning guest ran past 15s before, traps
  `out_of_fuel` in about 1s after.
- **`cljw.http.server` could be wedged by one unfinished request.** The
  accept loop had no read deadline, so a client that opened a connection and
  never completed the request head held the whole server — which binds
  0.0.0.0 — indefinitely. A request-head deadline now bounds it. Measured: a
  half-open connection blocked the next client for 12s before, 1s after.
  (Note: a serial server still handles one connection at a time; this bounds
  the wedge, it does not add concurrency.)
- **Namespace names with an empty segment resolved.** `(require (symbol
  "..a.b"))` could load `a.b` because the munge collapsed the doubled
  separator. JVM Clojure refuses such names; so does cljw now. These names
  cannot be written through the reader, so only computed namespace names are
  affected.

### Added

- **`run-server` accepts `:header-timeout-ms`** — how long a connection may
  take to deliver its request head. Default 10000; `0` disables the deadline.
- **`wasm/run` accepts `:fuel` and `:max-memory-pages`** — the same budget
  keys `wasm/load` already took. `0` or negative means unmetered, which is
  how you opt a trusted command out of the new default.

### Changed

- **zwasm pinned to v2.4.0** (its external-consumer release:
  `-Dcompiler-rt` for linking `libzwasm.a` from a non-Zig toolchain, and
  a DCE fix that keeps the WasmGC cohort out of sub-3.0 builds). Neither
  reaches cljw — cljw links zwasm through Zig, which supplies its own
  compiler-rt, and it builds at zwasm's default Wasm 3.0 level where the
  DCE guard is inert. Pin hygiene, not a behaviour follow; `-Dwasm`
  build + the phase16 wasm e2e suite verified green on the new pin.
- **Issues and Pull Requests are open.** Reports of Clojure code that
  behaves differently here than on the JVM are the most useful thing you can
  file; there is an issue template for exactly that. Outside contributors are
  explicitly not asked to follow the internal commit / ledger conventions —
  see CONTRIBUTING.

### Note for upgraders

Two behaviour changes can surface in working code:

1. `(wasm/run …)` is now fuel-bounded by default. A legitimately long-running
   guest that exceeds roughly 1e9 instructions will trap; pass `{:fuel 0}` to
   restore the previous unbounded behaviour.
2. `(require (symbol s))` with a computed `s` containing a leading, trailing,
   or doubled dot no longer resolves. Well-formed names are unaffected.

## [1.5.1] - 2026-07-17

Patch release: dependency follow.

### Changed

- **zwasm pinned to v2.3.0** (the WASI-0.3.0-official inventory-sweep
  release: docs truth-sweep against the officially released WASI 0.3.0,
  `wasi:clocks/system-clock` component-host support, Homebrew
  packaging). No embedding-API, behaviour, or JIT-output change — a
  pure engine follow; cljw's Wasm FFI surface is unchanged.

## [1.5.0] - 2026-07-17

Minor release: the host-class identity & member-surface campaign
(ADR-0174) — class symbols, class identity, and the Java member surface
become uniformly resolvable, precisely diagnosed, and machine-audited;
plus the user-requested Thread lifecycle.

### Added

- **Class symbols resolve as values everywhere**: bare `System` / `Math` /
  `Thread` / `StringBuilder` (java.lang auto-import), fully-qualified
  `java.util.Date` / `java.time.Instant` / …, and `(:import …)`ed names —
  in value position, `instance?`, `resolve`, `group-by class`, and across
  AOT round-trips. `(= java.util.Date (class d))` is identity on ONE
  canonical descriptor per class.
- **`Class` is first-class**: `(class Long)` → `Class` (was a raw internal
  tag leak), `(instance? Class (class 5))` → true.
- **Thread lifecycle** (user-requested): `(Thread. f)` / `(Thread. f name)`,
  `.start`, `.join` (+ ms), `.isAlive`, `.getName`/`.setName`,
  `.setDaemon`/`.isDaemon`, `Thread/yield`, `Thread/onSpinWait`, priority
  constants. JVM-faithful non-daemon default: main waits for live
  non-daemon threads at exit; `Thread/currentThread` returns the real
  per-thread object. Uncaught thunk errors print the JVM-style
  "Exception in thread" stderr line.
- **System close-out**: `getProperties` (map), 0-arg `getenv` (env map),
  `clearProperty`, `identityHashCode`, `gc`, and real stdio streams
  `System/in` / `System/out` / `System/err` (PrintStream-classed;
  `(.println System/err "…")` works; `System/in` reads stdin
  incrementally; `(instance? java.io.OutputStream System/out)` → true).
- **Constants sweep**: `Math/TAU`; `Long`/`Integer`/`Double`
  BYTES/SIZE/MIN_NORMAL; `File` separator/pathSeparator (+Char) +
  `createTempFile`/`listRoots`; `Pattern`'s 9 flag constants + 2-arg
  `Pattern/compile` (CASE_INSENSITIVE/MULTILINE/DOTALL/COMMENTS);
  `BigDecimal` ZERO/ONE/TWO/TEN; `Instant/EPOCH`, `Duration/ZERO`,
  `LocalTime` MIDNIGHT/NOON/MIN/MAX, `LocalDate`/`LocalDateTime`
  MIN/MAX/EPOCH; host-enum `values`/`valueOf` (+ `Month/of`,
  `DayOfWeek/of`).
- **java.time fill**: `Duration/parse` (full ISO-8601 grammar) +
  `Duration/of`, `LocalDate/ofEpochDay`, `LocalTime/ofSecondOfDay` +
  `ofNanoOfDay`.
- `scripts/check_compat_members.sh` — the member-truth gate: compat_tiers
  member lists are now machine-verified against the registered
  descriptors both ways (over-claims and silent omissions both fail);
  deliberately-skipped members are explicit `opaque_members:` rows.

### Changed

- **Host-class names are their JVM FQCNs**: `(class (java.util.Date. 0))`
  → `java.util.Date` (was `Date`), StringBuilder/Thread etc. no longer
  leak the internal `cljw.` prefix. cljw-native types, user records, and
  exceptions keep simple names (AD-003, clarified).
- **Member misses are precise diagnostics**: `(System/getProperties)` on
  a class without that member now says "No matching static method: … in
  class java.lang.System" instead of the misleading "No namespace:
  'System'" — every deliberately-skipped Java member renders this.
- fix(time): pre-year-0 civil date conversion was off by one era
  (`(.getYear (java.time.LocalDate/of -1 12 31))` was wrong); negative /
  5-digit years now print in JVM sign form.

### Breaking

- **`cljw build` artifacts from ≤ 1.4.0 (envelope ≤ v7) are rejected**
  by a 1.5.0 runtime — rebuild with the new `cljw build` (baked class
  constants changed spelling with the FQCN unification).
- `(class …)` output for Java-surface-backed values changed spelling to
  the JVM FQCN (see Changed) — string-matching on the old simple names
  (`"Date"`, `"Instant"`) needs updating; `instance?` / `=` code is
  unaffected (it got strictly more capable).

## [1.4.0] - 2026-07-16

Minor release: the binary-size campaign — the shipped binary shrinks
**9,469,816 → 6,974,584 bytes (−26.3%, now under 7 MB)** with no feature
loss and no safety-check loss (still ReleaseSafe), plus the envelope
format v7 it rides on.

### Changed

- **Binary size: 9.5 MB → 6.97 MB** (macOS arm64; Linux similar). The
  levers, all measured: unwind tables dropped from release builds
  (−739 KB — a stripped binary printed no native trace anyway); the
  AOT bootstrap gains an interned-name constant pool (42% of the blob
  was duplicate encoding) and flate-compressed lazy namespace regions +
  `.clj` sources (decompressed on demand); the embedded zwasm engine
  updated to v2.2.1 (its JIT host-callback thunk collapse, −1.08 MB
  as seen from cljw); shared sort instantiation. Full ledger:
  `.dev/decisions/0172_binary_size_budget_and_ledger.md`, public
  comparison: `docs/works/binary_size.md`.
- **Bytecode envelope format v7** (`.dev/decisions/0173_*.md`): 4-byte
  aligned wire instructions readable in place from the binary,
  per-blob constant pool, chunk `source_file`/`has_handlers` now
  serialized (AOT-restored fns can frame-flatten; error frames in
  bundled namespaces keep their real file labels), headerless nested
  fn chunks. Startup is unchanged within noise; RSS slightly lower.
- **zwasm pinned to v2.2.1** (binary-size campaign release; no API or
  JIT-output change).
- Cross-language benchmark records re-measured 2026-07-16
  (`bench/cross-lang-latest.yaml`, `bench/RELEASE_METRICS.md`: cold
  start ~6 ms on the shipped `-Dwasm` build).

### Breaking

- **`cljw build` artifacts made by 1.3.x (envelope ≤ v6) are rejected
  by a 1.4.0 runtime** with a version error — rebuild the app with the
  new `cljw build`. (Pre-2.0 format policy: the on-disk spec is
  archived per version in `docs/spec/formats/`; decoders are not kept.)

### Added

- `scripts/binary_size_report.sh` — size report / attribution tool +
  the `size_claims` gate (README size claim and the budget ceiling are
  now CI-enforced against the built binary).
- Guard e2e for VM error line:col fidelity across the new instruction
  encoding (`phase16_vm_error_loc_sidecar`).

## [1.3.1] - 2026-07-16

Patch release: Clojure 1.12 method values (`(every? Character/isWhitespace
s)` — the brew-user report), and defrecords gain their mainline
ns-qualified identity (`#user.Pt{…}` printing, reader round-trip, portable
record hash).

### Added

- **Method values (Clojure 1.12, static form)** — a bare `Class/method`
  in value position is the static method as a first-class fn:
  `(every? Character/isWhitespace s)`, `(map Character/toUpperCase "ab")`,
  `(sort-by Math/abs …)` all work as in mainline. (The 1.12
  `Class/.instanceMethod` / `Class/new` forms are tracked for a future
  release.)
- **Record literals read back** — `#user.Pt{:x 1, :y 2}` constructs the
  record through the reader (mainline parity; extra keys land in the
  extmap), so the printed form round-trips.
- **`scripts/nrepl_send.py`** — a dependency-free nREPL debug client
  (eval / describe / completions against a running server).

### Changed

- **Records print ns-qualified** — `#user.Pt{:x 1, :y 2}` (was `#Pt{…}`),
  matching mainline and making the print form readable.
- **Record hash values are portable** — `(hash (->Pt 1 2))` returns real
  Clojure's value (the qualified-name type-hash XOR the map hash),
  completing the 1.3.0 portable-hash work for records.

## [1.3.0] - 2026-07-16

Minor release: mainline-parity deep-dive — the `rt` namespace is gone
(`(resolve '+)` is `#'clojure.core/+`), CIDER completion reaches the
built-in nREPL completion's fidelity (classes and `Class/` static members
complete without `require`), `java.lang.Character` is complete, and
`(hash x)` values are now portable Clojure hash values.

### Added

- **`java.lang.Character` complete** — the full static surface (47 methods
  + 70 static fields incl. the category/directionality constants), with
  classification (`isLetter`, `isDigit`, `getType`, …) evaluated over
  generated UCD 16.0.0 tables — full Unicode, matching the JVM (previously
  ASCII-only). Includes the JDK 21 `isEmoji*` family, `getDirectionality`,
  the char/int overload pairs (`(Character/toUpperCase 97)` → `65`), and
  `.charValue` / `.compareTo` instance methods. The one member out:
  `getName` (explicit unsupported — the Unicode name table's size/value
  trade is tracked).
- **CIDER completion parity** — nREPL `completions` now serves every
  source the built-in serves: special forms + literals, vars with
  dash-fuzzy matching (`ma-i` → `map-indexed`), namespaces/aliases,
  classes, `Class/` static members with camelCase matching
  (`Character/isD` → `isDigit`), and interned keywords — by-name sorted,
  with `(clojure.core)`-correct namespace annotations. Java-interop
  completion works without `require`, from the closed class registry
  (no JVM-internal classpath leak).
- **`defmacro` resolves as a Var** (`#'clojure.core/defmacro`) and
  **`definline`** is available (defn-equivalent surface).
- nREPL `describe` advertises `versions.clojurewasm` (the babashka-style
  key a CIDER REPL banner can render).

### Changed

- **The internal `rt` namespace is GONE** — Zig builtins and bootstrap
  macros intern directly into `clojure.core`, so `(resolve '+)`,
  `(meta #'when)`, `(ns-publics 'clojure.core)`, doc/eldoc/completion
  namespaces, and printed values all match mainline. Kernel helpers live
  in the documented `cljw.internal` namespace. Compiled `.cljwc` archives
  from earlier versions need a rebuild (format v6).
- **Portable hash values** — `(hash x)` now returns real Clojure's value
  for strings, keywords, symbols, doubles, booleans, chars, UUIDs, ratios,
  BigDecimals, and every collection built from them (`(hash "abc")` →
  `74834163` everywhere). Records and identity objects remain
  cljw-specific.
- **`compare` returns mainline's magnitudes** for strings / chars /
  keywords / symbols (`(compare "a" "c")` → `-2`; Java `String.compareTo`
  semantics).
- **`(locking 5 …)` works** (immediates share one monitor; `(locking nil
  …)` errors, matching mainline's NPE).
- **`Double/parseDouble` matches the exact Java grammar** — accepts
  `1.5d`/`1.5F` suffixes and `0x1.8p1` hex floats; rejects lowercase
  `infinity`/`nan` and exponent-less hex.

### Fixed

- `(read-string "@x")` prints as `(clojure.core/deref x)` (was the
  internal `rt/deref`); `clojure.spec.alpha/form` shows
  `clojure.core/int?` (was `rt/int?`); syntax-quote and macroexpansion
  namespaces match mainline throughout.

## [1.2.1] - 2026-07-14

Patch release: the `*cider-error*` buffer works — CIDER renders numbered
causes with stack frames, phase-aware routing, and Show/Hide frame filters
against cljw, instead of "[no stack trace available]".

### Added

- **nREPL `cider/analyze-last-stacktrace` op** (+ the bare alias) — analyzes
  the session's `*e` on demand: one cause per `ex-cause` chain link with
  class / message / printed ex-data / error phase / stack frames
  (innermost-first, with `clj` / `repl` / `project` / `dup` flags and
  navigable `file-url` for on-disk frames). CIDER's rich error buffer and
  its compile-phase inline overlays activate automatically.

### Fixed

- **`*e` is now set for every caught REPL error** — Clojure parity:
  compiler-class errors (an unresolved symbol, a syntax error) previously
  left `*e` untouched; now `(ex-message *e)` works after any error, in both
  the CLI REPL and nREPL sessions.
- **`(throw (ex-info …))` carries a stack trace** — the live call stack is
  stamped on the thrown value, so user throws render frames like runtime
  errors (both backends).
- **nREPL use-after-free** — the 1.2.0 re-architecture fed the per-message
  scratch-owned request source into evals whose products outlive the
  message; long editor sessions could see corrupted strings. The source is
  now copied to the persistent arena.

## [1.2.0] - 2026-07-13

Minor release: the nREPL server is rebuilt to full base-protocol fidelity —
CIDER (and any nREPL editor client) now works end-to-end. Backward-compatible
with 1.1.x.

### Added

- **nREPL `completions` / `complete` ops** — editor completion (CIDER
  company/capf) over the live image: vars, macros, namespaces, aliases,
  `ns/var` qualified prefixes, with type annotations.
- **nREPL `lookup` / `info` / `eldoc` ops** — arglists + docstrings from var
  metadata; CIDER eldoc and `C-c C-d` documentation work.
- **`*1` / `*2` / `*3` / `*e` REPL history** — interned in `clojure.core`
  (upstream shape) and rotated by both the CLI REPL and every nREPL session
  (per-session isolation: tooling-session evals cannot touch your `*1`).
- **nREPL `ns` request handling** — evals honor the request namespace
  (`namespace-not-found` per spec); each session keeps its own current
  namespace, so an `in-ns` in one session never leaks into another.

### Fixed

- **CIDER REPL buffer was unusable** — the read loop blocked with complete
  requests already buffered, stranding pipelined messages off-by-one; the
  REPL prompt never rendered and RET did nothing. The transport now drains
  every buffered message before blocking.
- **Messages over 4 KiB reset the connection** — `C-c C-k` (load-file) on any
  real file killed the session. The receive buffer now grows (16 MiB frame
  cap).
- **Session identity** — every `clone` returned the same id and replies
  ignored the request's `session`; CIDER's two-session model (main + tooling)
  depends on both. Sessions are now distinct UUIDs and every reply echoes the
  request's `session` + `id`.
- **Error replies** — errors now carry the same caret-rendered text the CLI
  prints (was: a bare Zig error name like `NameError`), as the babashka-style
  three-message protocol (`err` → `ex`/`root-ex` + `eval-error` → `done`;
  was: bundled in one dict, which nREPL clients mis-route, plus a double
  `done`). Evaluation stops at the first failing form (JVM parity).
- **`*err*` output** is captured and streamed to the client alongside `*out*`.
- **`describe`** now derives its ops list from the dispatch table (they can
  no longer drift) and reports the real version (was: a stale hardcoded
  `0.1.0-pre`).

## [1.1.0] - 2026-07-12

Minor release: new REPL / tooling surface and Java-interop additions, a batch
of GC-correctness fixes, and a WebAssembly engine bump. Backward-compatible
with 1.0.x.

### Added

- **`clojure.repl` bundled** — `doc`, `find-doc`, `apropos`, `dir`, `demunge`,
  plus a bare `(doc x)` at the interactive prompt (clojure.main parity).
- **`:arglists` / `:doc` metadata** on `clojure.core` and the eager standard
  library vars — CIDER eldoc now resolves argument lists and docstrings.
- **Regex lookbehind** — `(?<=…)` / `(?<!…)` and `Pattern.split`.
- **`format` date/time** — the `%t` / `%T` conversion family (UTC, English).
- **Namespace metadata** — `alter-meta!` / `reset-meta!` on namespaces, and a
  namespace docstring / attribute map merged into the namespace metadata.
- **Java-interop surface** — common `java.util.Arrays` and
  `java.util.Collections` statics, `String` `char[]` forms, and JVM-bit-parity
  Murmur3 hashing.
- **`slurp` / `spit` accept open streams** (the remaining IOFactory arms).
- **WebAssembly FFI on zwasm v2.2.0** — up from v2.0.0 (table64 JIT +
  AOT full-fidelity); hot loops inside a module keep running as native code.

### Fixed

- **GC-correctness batch** — several use-after-free / corruption classes under
  frequent collection: unrooted analysis-time constants, tree-walk
  native-stack intermediates, `recur` reentrancy inside lazy `for`, and a
  `rest`-of-chunked-seq self-allocation hole that could corrupt a growing
  BFS-style queue. All now hold their roots across the collection.
- **Value semantics** — sorted collections work as hash keys / set elements;
  hash-map full-hash collision buckets match Clojure; `count` on a
  `CharSequence` `deftype`; `(var alias/x)` resolves namespace aliases;
  `read-line` reads process stdin; exception `str` / `pr` and
  `*print-readably*` shadowing match Clojure.

## [1.0.1] - 2026-07-02

Patch release: memory-safety fixes found by a post-release audit. No API
changes. Users on 1.0.0 should upgrade — the first item is reachable from
ordinary code.

### Fixed

- **Stack overflow on deep lazy chains** — realizing or counting a lazy
  sequence / cons chain longer than ~400k elements (e.g.
  `(count (repeat 1000000 1))`) crashed the process: the GC mark phase
  descended the object graph recursively on the native stack. Marking now
  uses an explicit gray worklist (O(1) stack for any depth).
- **Use-after-free family during analysis/compilation** — GC values created
  while a form is analyzed, compiled, or AOT-deserialized (literal strings,
  quoted data, chunk constants, macro-expansion intermediates) were not GC
  roots until execution, so a collection mid-analysis (large file loads,
  user-macro expansion) could recycle them — surfacing as per-run-varying
  `Unable to resolve symbol: '<garbage>'` errors, index-out-of-bounds
  panics, or spurious "host-marker method not yet wired" errors when
  loading bigger libraries (instaparse, math.combinatorics). A per-thread
  analysis-roots frame now keeps them alive; `deftype` / `reify` method
  tables are also traced (their method functions could be collected out
  from under a live type).
- **Namespace reflection errors are now catchable** — `ns-resolve`,
  `ns-map`, `ns-name`, `intern`, `create-ns`, `alias`, `find-var` and
  friends raised an uncatchable "not supported" error on a missing
  namespace or wrong-typed argument; Clojure raises a plain catchable
  exception there, and libraries rely on that for capability probes
  (`(try (ns-resolve …) (catch Exception e nil))`). They now match
  Clojure's exception classes.

## [1.0.0] - 2026-07-01

The first **stable** release. ClojureWasm is a JVM-free Clojure runtime written
in Zig, feature-complete for everyday Clojure with a WebAssembly FFI as its
headline capability. The WebAssembly FFI runs on the embedded **zwasm v2.0.0**
engine. Earlier pre-releases were tagged `1.0.0-alpha.*`. SemVer compatibility
guarantees start here.

### Added

- **Clojure language core** — reader, macros, destructuring, the sequence
  library, transducers, protocols, multimethods, `deftype` / `reify` /
  `defrecord`, metadata, namespaces with lazy loading, and the numeric tower
  (long / double / ratio / BigInteger / BigDecimal, JVM-surface semantics).
- **Standard library** — `clojure.core` plus `clojure.string` / `set` / `walk`
  / `zip` / `edn` / `data.json` / `data.csv` / `math` / `pprint` / `test` /
  `tools.cli` and more, reimplemented for the runtime.
- **WebAssembly FFI** — `(wasm/load "mod.wasm")` then `(wasm/call m "fn" …)`:
  load a sandboxed module compiled from any language (Rust, Go, Zig, C) and
  call it like an ordinary function. The FFI is **JIT-compiled by default** via
  the embedded **zwasm v2.0.0** engine, so a hot loop inside a module runs as native code.
- **WebAssembly components as namespaces** — `(:require ["comp.wasm" :as c])`
  pulls a WIT-typed component in like a library; its exports become ordinary
  Vars, with arguments and results as plain Clojure data.
- **CIDER-compatible nREPL** — `cljw nrepl` for live editor-connected eval.
- **Single-binary builds** — `cljw build script.clj -o app` compiles a program
  and the runtime into one self-contained native executable (arm64 / amd64).
- **Concurrency** — atoms, refs (STM), agents, promises, futures.
- **Java-interop surface** — a curated, definition-derived subset of common
  `java.*` classes (String / Math / java.time / BigInteger / BigDecimal /
  Character / …) reimplemented natively; see `data/compat_tiers.yaml`.

### Notes

- Behavioural equivalence with JVM Clojure is the target on the user-observable
  surface; intentional divergences are catalogued in
  [`docs/clojure_vs_clojurewasm.md`](docs/clojure_vs_clojurewasm.md).
- Licensed under EPL-2.0; third-party components in
  [`legal/THIRD_PARTY.md`](legal/THIRD_PARTY.md).
