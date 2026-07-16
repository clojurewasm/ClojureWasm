# ADR-0174: Host-class identity unification + member-surface completion campaign

- **Status**: Accepted (2026-07-17)
- **Driver**: user chat 2026-07-16 — `System` unresolvable in value position,
  `(System/getProperties)` → misleading "No namespace: 'System'",
  `(Thread. f)` ctor missing; user directed a campaign: fix the symmetry
  problems, add the members worth having, survey the other installed
  classes, release when done. Push + release explicitly authorized.
- **Inputs**: probe survey `private/notes/host-class-symmetry-campaign-survey.md`
  (639 static members probed: 381 present / 257 absent);
  mandatory DA fork `private/notes/host-class-symmetry-DA-critique.md`
  (Alt B adopted; its findings are folded in below).

## Context

Five user-visible defects share one root — class-name/identity truth is
dispersed and inconsistent across the host-class subsystem:

1. **Value-position asymmetry**: `Long`/`String`/`UUID`/`Object` resolve as
   class values (native/opaque/marker paths) but `System`/`Math`/`Thread`/
   `StringBuilder`/`java.util.Date` do not — `resolveClassValue`
   (analyzer.zig) never consults `host_class_resolve.resolve`, the only
   place the `cljw.` key translation + `java.lang` auto-import live.
2. **Misleading member-miss diagnostic**: a resolved class + missing member
   falls through to `namespace_unknown` ("No namespace: 'System'"); the
   analyzeList comment narrating a `symbol_unresolved` fall-through is stale.
3. **fqcn spelling zoo (user-visible leak)**: natives/user/exceptions =
   simple ("Long"); typed_instance impls = simple ("Date", "Instant");
   host-enums = JVM FQCN ("java.math.RoundingMode"); host_stream = JVM FQCN
   ("java.io.BufferedReader", corpus-pinned); host_instance surfaces MIXED —
   File = "java.io.File" but StringBuilder = "cljw.java.lang.StringBuilder",
   visible via `(class x)`, `.getName`, and print (`#<cljw.java.lang.Thread>`).
4. **typed_instance two-descriptor split**: Date/Instant/LocalDate/… carry a
   per-Runtime lazy impl descriptor (instances; fqcn "Date") + a static
   surface descriptor ("cljw.java.util.Date", `<init>` only). Consequences:
   `(instance? java.util.Date d)` → Name error, `(resolve 'java.util.Date)`
   → nil, and any fix that resolves the class symbol to the surface
   descriptor breaks `=` with `(class d)` — including across the AOT wire
   (serialize writes `descriptor.fqcn`; the import-blind
   `resolveDescriptorByKey` (ADR-0034 am5) would return the surface).
5. **`(class Long)` → "type_descriptor"** raw tag leak (clj: `java.lang.Class`).

Plus a process failure: `data/compat_tiers.yaml` member lists are rotted in
BOTH directions (Long/MAX_VALUE works but unlisted; MessageDigest/getInstance
listed but absent) — a one-time refresh without a mechanical gate re-rots
(F-013 clause 3).

## Decision

### D1+D2 — one canonical descriptor per class, JVM-FQCN identity (one unit)

**Identity rule (one line)**: a class backed by the Java-compat surface tree
(host_instance / typed_instance / host-enum / host_stream) has
`fqcn = its JVM FQCN`; cljw-native tags, user deftypes/records, the
Throwable family, interface markers, and `Object` keep SIMPLE names
(AD-003, amended to state this scope explicitly).

- All `cljw.`-prefixed descriptor fqcns become prefix-less JVM FQCNs
  (~25 surface files). rt.types keys stay `= fqcn` (mechanism unchanged).
- `host_class_resolve`: auto-import formats flip to `java.lang.{s}` /
  `java.math.{s}`; the now-dead `"cljw." ++ head` translation step and
  `displayName` are DELETED (fully-remove, no compat shim); `bareName`'s
  prefix tests flip to `"java.lang."` / `"java.math.Big"` (completion's
  bare-name source dies silently otherwise — nrepl completion e2e is the
  canary).
- Hardcoded `"cljw.java.*"` registry-key strings across the tree (Thread.zig,
  lang/Runtime.zig, _host_api tests, …) ride the same commit (grep-sweep;
  ~53 files carry the string).
- **Descriptor merge (typed_instance family)**: the rt.types-registered
  surface descriptor becomes THE descriptor — statics + `<init>` + instance
  methods in one `method_table`; instances carry it; the per-Runtime lazy
  impl descriptors (`rt.date_descriptor` … `rt.local_time_descriptor`) and
  their deinit paths are deleted; instance-method init moves into the
  surface `init` callbacks. This is "make the outlier match the norm" —
  host_instance classes (Thread/File/URI/…) already use one descriptor for
  both.
- **Equality stays identity** (clj oracle: JVM Class objects are
  singletons). The `ref_cache` interning invariant in type_descriptor.zig
  ("do NOT mint a fresh ref for an already-wrapped descriptor") is the
  guarantee. The DA-considered fqcn-string-`=` arm is REJECTED as unsound
  (no hash arm; breaks classes-as-map-keys; re-implements interning badly).
- **Collision guard**: `method_table` is flat (no static/instance bit).
  The merged family has no same-name static+instance member today
  (Integer/Long static `toString` is dodged because native instance dispatch
  uses the tag-keyed native descriptor). A registration-time assert fails
  loudly if a same-name pair ever lands on one descriptor; an `is_static`
  bit is the named escalation if a real collision is ever wired.
- `resolveClassValue` gains the `host_class_resolve.resolve` fallback
  (import-aware, analyzer side). `resolveDescriptorByKey` (shared with the
  AOT deserializer) stays import-blind and is CORRECT unchanged under the
  merge — the wire fqcn is the registry key.
- **Wire compat**: baked class-value constants change spelling
  ("Date" → "java.util.Date"), so `cljw build` artifacts from ≤1.4.0 are
  version-rejected — envelope bump v7 → v8, CHANGELOG breaking note (the
  in-tree bootstrap cache regenerates at build; no in-tree issue).
- Print/`.getName`/`str` of class values need no per-egress translation —
  the descriptor fqcn IS the user-facing name (the StringBuilder leak class
  dies structurally; Alt A's translation-at-every-egress was rejected as
  the Smallest-diff bias smell in canonical form).

### D3 — member-miss diagnostics (position-split, clj-shaped)

Two new error codes replacing the misleading fall-through:

- value position (analyzeSymbol, bare `Class/member` symbol):
  `static_field_unknown` — "Unable to find static field: {member} in class
  {class}" (clj's wording).
- call position (analyzeList, `(Class/member …)` head with resolved class +
  member miss): `static_method_unknown` — "No static method '{member}' on
  class {class} (not defined, or not implemented in ClojureWasm)".

`isDeferredHostNs` (clojure.lang.* / clojure.asm.*) keeps the AD-008
deferred-rewrite path — member-miss there must NOT hard-fail analysis.
The stale analyzeList comment is fixed in the same commit.

### D4 — `Class` becomes a first-class marker

- `fqcnForTag(.type_descriptor)` → "Class": `(class Long)` → `Class`.
- Bare `Class` resolves as a class value (classDescriptor marker, like
  `Object`); `(instance? Class (class 5))` → true (tag arm).
- `Class/forName` → explicit OPAQUE row (no classpath; F-014 clause 2
  forbids silent absence next to a freshly-minted name).

### D5 — System close-out

- Add: `getProperties` (cljw persistent map of the static table + the
  existing `rt.system_properties` overlay — `setProperty` already exists;
  map-not-Properties recorded as an AD), 0-arg `getenv` (env map),
  `clearProperty` (overlay remove, returns previous), `identityHashCode`
  (cljw identity hash — heap pointer / immediate bits; AD note: not JVM
  object headers), `gc` (real collect trigger).
- Static fields `in`/`out`/`err`: real stdio-backed stream singletons
  (ADR-0087 heap-singleton static-field precedent). `out`/`err` are a new
  `print_stream` stream kind — chain {PrintStream, FilterOutputStream,
  OutputStream}, PrintStream REMOVED from `SIBLING_NAMES` (the "never
  produced" invariant edit is owned here); methods write/print/println/
  flush; println autoflushes (JVM stdout oracle) so cljw's own buffered
  print path and System/out writes do not interleave nondeterministically.
  `in` reuses the input kind over stdin (clj `(class System/in)` =
  BufferedInputStream = our input concrete).
- Skipped members (console, getLogger, load, loadLibrary, mapLibraryName,
  inheritedChannel, setIn/setOut/setErr, setProperties, SecurityManager
  family, runFinalization) = explicit OPAQUE rows + D3's clean error.

### D6 — Thread lifecycle surface (user-authorized F-014 exception)

F-014 lists "OS threads-as-Java" OUT; the user's 2026-07-16 chat directive
authorizes the minimal lifecycle surface (F-014 Revision history entry rides
this ADR's commit). New `runtime/thread.zig` neutral impl on the future.zig
worker pattern (std.Thread + ThreadGcContext + gc.pin + Io.Mutex/Condition):

- `(Thread. f)` / `(Thread. f name)` ctor; `.start` (second start →
  IllegalThreadState-shaped error), `.join` (0-arg + ms arg), `.isAlive`,
  `.getName` / `.setName`, `.setDaemon` / `.isDaemon`, auto-names
  "Thread-N".
- **Non-daemon default is JVM-faithful**: a live non-daemon thread registry
  is joined at main exit (the DA-flagged silent daemon-true divergence is
  thereby dissolved; `setDaemon(true)` = removed from the join-set —
  both values real, no accept/error split).
- `Thread/currentThread` returns a threadlocal per-OS-thread object (fixes
  the existing `.getName`-hardcodes-"main" lie; pinned by test); statics
  `yield`, `onSpinWait`, fields MIN/NORM/MAX_PRIORITY (1/5/10).
- interrupt family (interrupt/isInterrupted/interrupted) → unsupported
  error + debt row (a flag-only interrupt that cannot wake a sleeping
  thread would be a semantic lie); get/setPriority → OPAQUE rows.

### D7 — constants + enum statics + Pattern flags

- Constants: BigDecimal ZERO/ONE/TWO/TEN; Math/TAU; File separator/
  separatorChar/pathSeparator/pathSeparatorChar + createTempFile/listRoots;
  Long/Integer/Double BYTES/SIZE (+ Double MIN_NORMAL); Instant
  EPOCH/MIN/MAX; Duration/ZERO; LocalTime MIDNIGHT/NOON/MIN/MAX;
  LocalDate/LocalDateTime MIN/MAX (+ LocalDate/EPOCH). Java-19+ additions
  (TAU, TWO) verified against the local clj oracle before corpus-pinning.
- Host-enum uniform statics via the ADR-0161 registry: `values` (returns a
  cljw Java array — `(vec (Month/values))` oracle-checked), `valueOf`, and
  `of` where JVM has it (Month, DayOfWeek) — one stroke for RoundingMode/
  ChronoUnit/Month/DayOfWeek.
- Pattern: the 9 flag int constants + 2-arg `Pattern/compile` mapping
  {CASE_INSENSITIVE→(?i), MULTILINE→(?m), DOTALL→(?s), COMMENTS→(?x)};
  other flags → unsupported error. The regex value stores DISPLAY source
  separately from compiled source so `(str p)` returns the original
  pattern (clj fidelity).

### D8 — java.time fill (bounded)

`Duration/parse` (ISO-8601), `Duration/of(amount, ChronoUnit)`,
`LocalDate/ofEpochDay`, `LocalTime/ofSecondOfDay` + `ofNanoOfDay`.
TemporalAccessor machinery (from/query/range/adjustInto/with) stays OUT —
OPAQUE rows (JVM temporal-framework depth, not linguistically general).
ZonedDateTime remains D-105 (unbuilt; out of campaign).

### D9 — data truth + the mechanical member gate (F-013 clause 3)

- New hidden CLI flag `cljw --dump-host-classes` prints machine-readable
  EDN of every registered surface class (fqcn, static fields, methods) —
  reusing the completion introspection walk (a future `--list-vars`
  building block).
- New gate `scripts/check_compat_members.sh` (wired into the full gate):
  (a) every compat_tiers.yaml listed member exists on the registered
  descriptor; (b) every descriptor member is listed OR has an explicit
  OPAQUE row. compat_tiers.yaml schema gains `opaque_members:` per class.
- compat_tiers.yaml refreshed from dump truth for all 41 surface classes
  (fixes both rot directions; MessageDigest's aspirational `getInstance`
  row corrected to match D-106 reality).
- Debt: new rows for Thread-interrupt, instance-method fills judged out of
  this campaign (StringBuilder set, File instance set, Locale, Matcher,
  Socket); Alt C (single class-registry naming SSOT, `class_name.zig` +
  `host_class_resolve.zig` + rt.types keys + compat rows derived from one
  table) recorded as the named follow-on debt row with this ADR as
  prerequisite.

## Implementation order

D1+D2 (one unit; smoke diff-oracle early — descriptor dispatch is hot) →
D3 → D4 → D5 → D6 → D7 → D8 → D9 → docs/CHANGELOG → full gate
(--serial-e2e, ALONE) + ubuntunote → release v1.5.0 → tap bump.

## Alternatives considered (DA fork, verbatim conclusions)

- **Alt A (smallest-diff)** — keep all keys/fqcns; fix leaks point-wise by
  routing every egress through `displayName`; add only the resolveClassValue
  fallback + features. Rejected: institutionalises the spelling zoo behind a
  translation layer every FUTURE egress must remember (the StringBuilder
  leak exists precisely because one egress forgot) — Smallest-diff bias in
  canonical form; leaves the two-descriptor `=` problem unsolved (F-002).
- **Alt B (adopted)** — D1 + descriptor merge as one unit; identity
  equality becomes structural (one canonical descriptor per class), fixing
  `=`, instance?, resolve, completion, and the AOT wire with zero routing
  arms; deletes ~8 lazy descriptor fields. Cost: substantially larger diff
  (time/*.zig lifecycle reconciled to the registerExtension gpa contract) —
  recommended anyway citing F-002.
- **Alt C (wildcard)** — one `class_registry.zig` owning ALL class-name
  truth (native tags / surfaces / markers / siblings / OPAQUE as kind-tagged
  rows), from which class_name.zig, resolution, completion, and the yaml
  recognition rows derive. Attacks the root cause of the zoo; largest
  surgery; recorded as the follow-on debt row (prerequisite: this ADR),
  not this cycle's scope.
- **fqcn-string-based `=`** (draft's open D2 branch) — struck as unsound:
  no `.type_descriptor` equality/hash arm exists; string-`=` without a hash
  arm breaks classes-as-map-keys; the ref_cache interning invariant already
  guarantees identity correctness for a canonical descriptor.

## Consequences

- `(class x)` name universe becomes two-regime and stable: simple for
  cljw-native/user/exception/marker types (AD-003), JVM FQCN for
  Java-surface-backed classes (clj-faithful; matches the already-pinned
  stream/enum behaviour).
- `(= java.util.Date (class d))`, `(instance? java.time.Instant i)`,
  `(resolve 'java.lang.System)`, bare `System`/`Math`/`Thread`/
  `StringBuilder` as values, and `(group-by class …)` with host classes all
  work — including across AOT round-trips.
- Every unimplemented-member hit becomes a precise, clj-shaped diagnostic
  instead of "No namespace".
- compat_tiers.yaml member truth is machine-guaranteed from this ADR on.
- Breaking: `cljw build` artifacts from ≤1.4.0 are version-rejected (v8
  envelope); `(class (java.util.Date. 0))` prints `java.util.Date` (was
  `Date`) — corpus pins updated, AD-003 amended.

## Affected files (representative, not exhaustive)

`src/eval/analyzer/analyzer.zig`, `src/eval/analyzer/special_forms.zig`,
`src/runtime/host_class_resolve.zig`, `src/runtime/class_name.zig`,
`src/runtime/type_descriptor.zig`, `src/runtime/runtime.zig`,
`src/runtime/java/**` (~25 fqcn flips + System/Thread/Pattern/File/Math/
BigDecimal/time surfaces), `src/runtime/time/*_value.zig` + `date.zig`
(descriptor merge), `src/runtime/io/stream_classes.zig` +
`host_stream.zig` (print_stream kind), new `src/runtime/thread.zig`,
`src/runtime/error/catalog.zig`, `src/app/cli.zig` (--dump-host-classes),
`scripts/check_compat_members.sh` (new gate), `data/compat_tiers.yaml`
(refresh + opaque_members schema), `.dev/accepted_divergences.yaml`
(AD-003 amendment + new ADs), `.dev/project_facts.md` (F-014 revision),
`.dev/debt.yaml`, envelope version (v8), corpus/e2e updates.

## Revision history

- 2026-07-17: Accepted. DA fork output folded in (Alt B); campaign started.
