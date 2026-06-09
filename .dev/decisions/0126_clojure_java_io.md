# ADR-0126 — clojure.java.io + java.io.File (full surface, cljw-style)

- Status: Proposed → Accepted
- Date: 2026-06-09
- Deciders: autonomous loop (user-directed: "clojure.io の機能を full に入れたい")
- Tier: B (ROADMAP §6 host class table: `clojure.java.io: B # same names,
  Zig-native I/O backing`; `java.io.File: B # via clojure.java.io`)

## Context

The babashka-independent playground (D-355) needs file existence checks,
path manipulation, and (eventually) binary serving. More broadly the user
directed a **full** introduction of `clojure.java.io`, settling in for the
long haul ("時間がかかってもよい / しっかり腰を据えて"), doing it in
ClojureWasm style where the JVM mechanism does not map, completing the
partial `java.io.File` skeleton along the existing flow, and enumerating
gaps for an ideal-form introduction.

`clojure.java.io` (upstream `src/clj/clojure/java/io.clj`) is a polymorphic
I/O system built on two protocols + a multimethod:

- **Coercions** — `as-file`, `as-url`.
- **IOFactory** — `make-reader`, `make-writer`, `make-input-stream`,
  `make-output-stream`; with public wrappers `reader`/`writer`/
  `input-stream`/`output-stream`.
- **do-copy** — a `defmulti` keyed on `[(type input) (type output)]`,
  surfaced as `copy`.
- Plus `file`, `as-file`, `as-relative-path`, `delete-file`,
  `make-parents`, `resource`.

### Prerequisite chain (verified 2026-06-09)

- `extend-type` / `extend-protocol` work (macro_transforms.zig → `rt/__extend-type!`).
  Upstream's `(extend T IOFactory (assoc default-streams-impl …))` fn-form is
  re-expressed cljw-style with `extend-protocol` + explicit per-type impls.
- `defprotocol` / `defmulti` / `defmethod` / `with-open` / `reify` /
  `deftype` all present; `type` fn present; defmulti vector-dispatch is
  e2e-tested (phase7/phase15).
- Canonical host-type pattern = `runtime/java/util/Random.zig`: a
  `.host_instance` (ADR-0106) carrying a per-instance `*const TypeDescriptor`,
  `<init>` + instance methods registered into `method_table` in the `init`
  callback. Dispatch: analyzer → `InteropCallNode{.instance_member}` →
  `tree_walk.evalInstanceMember` → `td.lookupMethod`.
- FS-jail (`file_io.zig`, ADR-0123): every FS-touching op routes the path
  through the jail resolve and maps `error.FsJailEscape` → `.fs_jail_escape`.

## Decision

Introduce `java.io.File` (full method surface) + a `clojure.java.io`
namespace covering the **char/text + File + stream-object** surface that
cljw's current phase supports without unwinding a deferred structural
decision. Land it in coherent, individually-gated TDD cycles:

1. **java.io.File host type** — rebuild the `runtime/java/io/File.zig`
   skeleton from the (wrong) typed_instance `field_layout` shape to the
   `host_instance` shape (`fqcn = "java.io.File"`, payload = path string).
   Methods: `exists`, `isFile`, `isDirectory`, `getName`, `getPath`,
   `getAbsolutePath`, `getCanonicalPath`, `getParent`, `getParentFile`,
   `length`, `isAbsolute`, `canRead`, `canWrite`, `delete`, `mkdir`,
   `mkdirs`, `list`, `listFiles`, `toString`; 1- and 2-arg ctor. FS-touching
   methods reuse the jail; pure path ops (getName/getParent/…) skip it.
   Neutral impl in `runtime/io/` per F-009.

2. **Coercions + file family** — `clojure.java.io.clj` embedded via
   bootstrap. `as-file` (String/File/nil), `file`, `as-relative-path`,
   `delete-file`, `make-parents`.

3. **Host stream types — ONE generic `host_stream` representation**
   (adopting Devil's-advocate Alt 2, F-002). A single `host_instance`
   carrying a Zig handle/buffer + a `kind` tag
   (`{input,output,reader,writer} × {file,buffered,string,byte}`) +
   direction/encoding. The JVM class *names* (`BufferedReader`,
   `FileInputStream`, …) are **rows in a closed-set descriptor table**
   (the F-013 / ADR-0102 `host_interfaces.yaml` pattern) that all route to
   the one generic stream surface — NOT ~10 sibling TypeDescriptors. Under
   the no-JVM rule (ADR-0059) there is no `extends` relationship to model
   (`BufferedReader is-a Reader` is a JVM-class-hierarchy fact cljw does not
   represent), so minting a class tree would import a hierarchy the project
   rejected. **Binary stream transport lands NOW**: the payload lives in a
   Zig `[]u8` inside the host instance and never surfaces as a cljw
   byte-array Value, so D-051 does not block it (D-051 defers the byte-array
   *Value*, not byte *transport*). FS-jail (`jailResolve`) is applied at
   every stream-open site, not just `slurp`/`spit`.

4. **IOFactory** + `reader`/`writer`/`input-stream`/`output-stream`.

5. **copy** (`do-copy`) over File/Reader/Writer/InputStream/OutputStream/
   String — incl. binary stream-to-stream / stream-to-file (Zig `[]u8`
   buffers). This is what the playground needs to serve binary wasm/png.

6. **resource** — no classpath concept in cljw → explicit
   `feature_not_supported` + debt.

7. **cljw.json + cljw.fs wrappers** — require-able `cljw.*` aliases. Per
   F-009 the JSON parse/emit + map↔value conversion bodies live in a
   **namespace-neutral impl** (`runtime/json.zig` + a fs-helper impl);
   `cljw.json`/`cljw.fs` (and the existing `clojure.data.json` surface) are
   thin wrappers over it — never a fork. `read-str` 2-arity `:key-fn`/
   `:value-fn` coercion lives in the neutral impl.

### Deferral boundary (cljw-style / phase-gated, each a tracked debt row)

- **byte-array-Value-facing arms only** — `(.read stream ba off len)` into a
  cljw byte-array, and the byte-array / char-array `IOFactory` + `do-copy`
  arms — depend on the cljw byte-array Value representation, deferred to
  Phase 16 (D-051, F-003). The generic `host_stream` reserves these method
  slots as transient `feature_not_supported` stubs so the Phase-16 landing
  is a wire-in, not a struct migration. **Binary byte transport is NOT
  deferred** (see Decision item 3).
- **URL / URI / Socket coercions + IOFactory arms** — no host types yet
  (ROADMAP `java.net.*` Phase 14+). Ship as `feature_not_supported`.
- **resource** — needs a classpath/classloader concept cljw lacks.

These are not workarounds: the underlying subsystem genuinely does not
exist at this phase. Each is recorded so the surface is honestly partial,
not silently lying (per `provisional_marker.md` / no-op-stub rules).

## Consequences

- File + stream host types are the first sizeable host-object subsystem;
  they establish the Zig-file-handle-backed stream pattern future I/O
  (sockets, channels) reuses.
- `clojure.java.io` becoming real unblocks the D-355 playground port's file
  ops without babashka.fs.
- The deferral rows keep the URL/Socket/byte-array gaps visible for the
  phase that owns them.

## Alternatives considered

> Devil's-advocate subagent (fresh context) output, reflected verbatim. The
> main loop **adopted Alt 2** (its recommendation), revising Decision items
> 3, 5, 7 + the deferral boundary above to match.

The 7-cycle draft (full `java.io.File` surface + `clojure.java.io`
Coercions/IOFactory/copy + ~10 stream host TypeDescriptors mirroring JVM
class names + `cljw.json`/`cljw.fs`, with byte-array/binary-I/O and
URL/URI/resource deferred) was stress-tested against the F-NNN envelope.
Three alternatives within those constraints:

### Alt 1 — Smallest-diff: File + char/text streams only, drop the IOFactory/copy/json/fs layers this cycle

**Shape.** Cycles 1+3 only: rebuild `java.io.File` to the `host_instance`
shape, plus the char/text stream host types
(`Reader`/`Writer`/`BufferedReader`/`StringReader`/`PushbackReader`) backed
by Zig `[]u8`. `clojure.java.io` ships just
`as-file`/`file`/`delete-file`/`make-parents` + a 1-arm `reader`/`writer`
over File. No `IOFactory` protocol, no `do-copy` defmulti, no
`cljw.json`/`cljw.fs`, binary streams deferred alongside byte-arrays.

**Better than the draft.** Lands File + the highest-frequency
`slurp`/`with-open`/`line-seq` path with the least surface; defers every
multi-arm protocol/defmulti until the byte-array repr question is settled,
so nothing built this cycle has to be revisited when D-051 closes. Cleanest
*per-cycle* closure.

**What it breaks.** It is a **drip-feed of one coherent surface** —
`clojure.java.io` is a single conceptual unit (Coercions + IOFactory + copy
together), and shipping `reader`/`writer` without the `IOFactory` protocol
means the dispatch backbone gets retrofitted later rather than designed
once. That is the Micro-coverage-grind / Smallest-diff-bias pattern F-002 +
`clj_diff_sweep.md` Discipline 2 forbid: a half-covered `clojure.java.io`
reads as "covered" in the ledger while the protocol that makes it
extensible is absent. Recommended against on F-002 grounds (cycle-count is
not a constraint).

### Alt 2 — Finished-form-clean: ONE generic host-stream type + binary streams land NOW; mirror-class names become descriptor metadata, not distinct TypeDescriptors

**Shape.** Two corrections to the draft, both F-013/no-JVM-driven:

1. **One `host_stream` representation, not ~10 class-named
   TypeDescriptors.** A single host-instance carrying a Zig handle/buffer +
   a `kind` tag (`{input,output,reader,writer} × {file,buffered,string,byte,
   pushback}`) + a `direction`/`encoding` field. The JVM class *names*
   (`BufferedReader`, `FileInputStream`, …) become **rows in a closed-set
   descriptor table** (the F-013 / ADR-0102 `host_interfaces.yaml` pattern)
   that all route to the one generic stream surface — exactly clause 3 of
   F-013 ("every recognised entry routes to a *generic* surface; a
   per-library shim has no slot"). Under the no-JVM rule (ADR-0059:
   TypeDescriptor, no Class hierarchy) there is **no `extends` relationship
   to model** — `BufferedReader is-a Reader` is a JVM-class-hierarchy fact
   cljw explicitly does not represent, so minting 10 sibling TypeDescriptors
   imports a hierarchy the project rejected. `instanceof`/`isa?` questions
   answer off the `kind`/`direction` fields, not a descriptor parent chain.
   This also collapses the F-004 slot pressure (one `host_instance` slot vs.
   a family).

2. **Binary streams (`InputStream`/`OutputStream`/`FileInputStream`/
   `FileOutputStream`/`ByteArray*Stream`) land NOW**, because **D-051 is not
   actually a blocker for them.** D-051 defers the *cljw byte-array Value*
   (`[]Value`, one Value/byte). A binary stream's payload lives in a **Zig
   `[]u8` inside the host instance** and never surfaces as a cljw Value —
   identical to how the draft's char/text path already holds `[]u8` without
   surfacing a cljw string-of-bytes. The only operations that *require* a
   byte-array Value are `(.read stream byte-array off len)` and the
   byte-array `do-copy`/`IOFactory` arms — those, and only those, defer to
   Phase 16. `(io/copy in-stream out-stream)`,
   `(io/input-stream "f.png")`, stream-to-stream
   `(io/copy (io/input-stream src) (io/output-stream dst))` all work today
   over `[]u8` buffers. **This is the load-bearing finding for question
   (a):** the playground serving binary wasm/png is *stream-to-stream /
   stream-to-file copy*, which needs zero byte-array Value. Deferring all
   binary I/O conflates "byte-array Value" (correctly deferred per
   D-051/F-003) with "binary byte transport" (not blocked). Deferring
   transport is a smallest-diff convenience the finished-form owner would
   unwind, and it leaves the playground's actual use case unserved.

   *Confinement (question c):* `jailResolve` is a stateless lexical resolve
   called at open time and returns the confined path; it does not enforce
   per-read. For long-lived open streams this is **correct as-is** — the
   file handle is bound to the jail-resolved path at open, and the OS handle
   cannot later escape the jail (the path was validated before `openFile`).
   The residual is the documented D-342 symlink-inside-jail case, which is
   orthogonal to stream lifetime. No new confinement model is needed; the
   draft's "reuse the slurp/spit jail" is right, *provided* the jail resolve
   happens at every stream-open site (not just `slurp`/`spit`) — make that
   an explicit cycle-3 assertion.

3. **json/fs map-conv handy fns live in a namespace-neutral impl (F-009),
   not in `cljw.json`/`cljw.fs`.** Per F-009 the JSON parse/emit +
   map-conversion bodies belong in `runtime/json.zig` (+ `runtime/fs.zig`
   for path handy fns); `cljw.json`/`cljw.fs` are **thin Clojure/cljw-surface
   wrappers** over them, and — critically — so is any future
   `clojure.data.json` compatibility surface. Forking the impl into a
   `cljw.json`-owned body (question d: alias-vs-fork) would re-create the
   cw-v0 anti-pattern F-009 was written to kill (impl trapped inside one
   surface, unshareable). So: **neutral impl + thin wrapper, never fork.**
   `read-str :key-fn` keyword-coercion lives in the neutral impl.

**Better than the draft.** Aligns with the project's two structural laws
that the draft half-followed: no-JVM (one descriptor, not a mirrored class
tree) and F-013 (closed-set table routing to a generic surface). Serves the
playground's binary use case *now* without violating D-051. Puts json/fs
impl where F-009 mandates so the eventual `clojure.data.json` surface is a
wrapper, not a rewrite. Collapses F-004 slot consumption.

**What it breaks.** Larger diff this cycle (one richer host-stream module +
a descriptor table + binary open/copy paths). Per F-002/F-011 this is
**not** a reason to downgrade — cycle/diff/LOC is not a project constraint.
The one genuine cost: the generic-stream `kind` tag must be designed to
admit the deferred byte-array `read(ba,off,len)` arm without reshaping when
D-051 closes — i.e. the host-stream struct reserves the byte-array-facing
method slots as `feature_not_supported` stubs (transient-stub row of
`provisional_marker.md`), not absent fields. That keeps the Phase-16
byte-array landing a wire-in, not a struct migration.

### Alt 3 — Wildcard: define byte-array repr now as a host-instance over Zig `[]u8`, decoupled from D-051's `[]Value` collection-tower question

**Shape.** Observe that D-051 is specifically about the *collection-tower*
byte-array (the `[]Value` representation that participates in
`seq`/`conj`/`aget` as a first-class persistent-ish value, deferred to
Phase 16 with the rest of the Java-array tower per F-003). But a
**transport-only byte buffer** — a `host_instance` wrapping a Zig `[]u8`,
supporting only `aget`/`alength`/`(.read …)`/`(.write …)` and round-tripping
through streams — is a *different object* that could land now and satisfy
`(byte-array n)`, `(.read in buf)`, the byte-array `IOFactory`/`do-copy`
arms, and binary `slurp` returning bytes. Phase 16's `[]Value` tower would
then either subsume or coexist with it.

**Better than the draft (and Alt 2).** Unblocks the *complete*
`clojure.java.io` surface incl. every byte-array arm in one push (true
big-bang per Discipline 2), and gives the playground binary read-into-buffer,
not just stream-to-stream copy.

**What it breaks — and the F-NNN finding (leading entry).** This is **the
alternative that requires violating an F-NNN**, recorded first per the
brief. D-051 + F-003 deliberately defer the byte-array *representation
decision* to the Phase 16 owner (the Java-array tower owner), because
byte-array repr is a **structural plan** (it interacts with the F-004 slot
map's `array` slot in Group D, the numeric-tower boxing of byte values, and
`aget`/`aset` polymorphism across all primitive array types). Minting a
*second* byte-array object now — even a "transport-only" one — is exactly
the decision-seizure F-003 forbids: it pre-commits the Phase-16 owner to
either subsume or reconcile a representation the current cycle invented,
which is the structural pre-emption F-003 exists to prevent. The "it's a
different object" framing is the rationalization that makes it feel safe; in
finished form there is **one** byte-array concept and its shape is the
Phase-16 owner's call. **Verdict: rejected — violates F-003 (structural
decision-deferral) and front-runs D-051.** The transport need it targets is
already met by Alt 2's Zig-`[]u8`-inside-the-stream (which surfaces *no*
byte-array object at all), so the F-003-violating path buys only the
byte-array-Value-facing arms, which are correctly Phase-16 work.

**Recommendation (non-binding):** Take **Alt 2** — one generic
`host_stream` + closed-set descriptor table (no-JVM/F-013), binary stream
*transport* landed now over Zig `[]u8` (D-051 does not block it; the
playground needs it), json/fs impl in neutral files with thin `cljw.*`
wrappers (F-009), byte-array-Value-facing arms left as transient
`feature_not_supported` stubs for Phase 16.
