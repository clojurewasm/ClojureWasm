# ADR-0162 — Cold-start bootstrap architecture: lazy-namespace bytecode + zero-copy deserialize now; heap-snapshot deferred to the GC unit

- **Status**: Proposed → Accepted (2026-06-24; D-450 startup-floor lever; DA-fork incorporated verbatim below)
- **Driven by**: D-450 (gap-III fastest-script campaign) reconstructed lever order
  named the **startup floor** as the highest cross-cutting lever (it is added to
  EVERY cold bench, and the top gap `sieve` is floor-sensitive). Measure-first
  (2026-06-24) attributed the floor; this ADR fixes the architecture the floor work
  follows so the optimisation does not drift into the cljw-v0 "Zig-ify the bootstrap"
  rut or into an impressive-but-wrong heap-snapshot.
- **Relates to**: ADR-0056 (AOT bytecode envelope — the mechanism this evolves),
  ADR-0034 am1 (interleaved chunk envelope), ADR-0158 (single-binary embedding),
  D-140 (self-exe footer-seek), D-452 (the eager-whole-bootstrap blob this re-laces),
  D-515 (binary-size axis), the "Eager comprehensiveness vs single-binary size/startup"
  standing tension (debt.yaml, F-013 clause 4). F-002 (finished-form wins), F-004
  (NaN-box 64-slot, absolute pointer in payload), F-006 (mark-sweep GC, non-moving),
  F-011 (behavioural equivalence), F-013 (single-binary, no side artifacts).
- **User-declared invariant honoured**: the optimisation NEVER moves a `.clj`-defined
  var into hand-written Zig (the cljw-v0 89K-LOC rut); it touches only the RESTORE
  MECHANISM and the EAGER SET. .clj stays the definition language.

## Context

`cljw -e 1` cold floor ≈ 9.4 ms (quiet Mac M4 Pro, ReleaseSafe). Env-gated profiler
(`CLJW_PROFILE_STARTUP=1`, ADR-introduced) attribution:

| phase                                     | time    | note                                                            |
|-------------------------------------------|---------|-----------------------------------------------------------------|
| self-exe read (`tryRunEmbedded`, cli.zig) | ~1.0 ms | reads the whole 8.8 MB binary to check a 12-byte footer (D-140) |
| `runEnvelope` deserialize                 | ~2.1 ms | parse 891 bytecode chunks into heap structures                  |
| `runEnvelope` vm.eval                     | ~2.5 ms | intern vars, build collections, def fns                         |
| `registerAll` (primitives)                | ~0.2 ms | —                                                              |
| exec/linker/page-fault residual           | ~3.4 ms | un-addressable process overhead (in-process-unmeasured)         |

The eager bootstrap is **891 chunks**: clojure.core = 294 top-level forms (~21%); the
~28 non-core stdlib namespaces (string/set/walk/zip/edn/data.json/data.csv/tools.cli/
pprint/test/data/math/spec.alpha/…) = 1148 forms (**~79%**). A `cljw -e 1` one-liner —
and most edge handlers — touch essentially only clojure.core. D-452 Part B made all 29
namespaces one eagerly-replayed blob "so non-core libs no longer re-parse from source";
that fixed a re-parse cost by paying a full eager-replay cost. Neither "lazy + bytecode"
(no re-parse AND no eager replay) nor "no replay at all" exists yet.

An industry survey (SBCL `save-lisp-and-die`, Emacs pdumper, V8 snapshots, GraalVM
image-heap, Ruby bootsnap, PEP 690) found: runtimes that beat ~5 ms do not replay a
bootstrap — they **map a build-time heap snapshot**. cljw is at the "bootsnap tier"
(replay precompiled bytecode); `@embedFile` already removes the disk-IO bootsnap targets,
so that tier offers nothing new. The headline industry answer is a heap snapshot
("Candidate B").

A devil's-advocate red-team (folded verbatim below, checked against `nan_box.zig`,
`cache_gen.zig`, `mark_sweep.zig`, `root_set.zig`) inverted the front-runner: **B buys
only core's ~1 ms replay share, behind a ~3.4 ms un-addressable wall, at the cost of the
worst bug class this codebase can ship** (a single un-relocated absolute / `builtin_fn`
pointer = silent heap corruption with no fault), a second per-tag relocate-slot
reflection surface the GC does not provide today, and a per-target cache_gen↔runtime
layout-skew build-matrix lock. B is also GC-coupled: a future moving/generational GC
already needs the identical "rewrite every pointer slot" machinery and may adopt
base-relative encoding that makes snapshot relocation free — so building B now against
the non-moving GC is a twice-built / soon-unwound shape (Smallest-diff-bias-against-
finished-form smell).

## Decision

Pursue the cold-start floor in this sequence; each step is GC-independent and never
touches the F-004/F-006 pointer surface:

1. **D-140 — self-exe footer-seek.** `stat` the binary size, seek, read only the last
   12 bytes (the `[u64 len]["CLJC"]` footer); positioned-read the payload region only on
   a magic match. Removes the ~1 ms whole-binary read on every normal startup.
   Independent, trivial, zero risk. **Land first.**

2. **Lazy-namespace bytecode loading (Candidate A).** The eager set shrinks to the true
   minimal "needed for the default runtime to behave correctly with no `require`" =
   clojure.core + its load-time dependencies (e.g. core.protocols / the error-render
   peer / core macros' helpers — determined by audit, not guessed). Every other namespace
   becomes its **own embedded bytecode envelope** (still `@embedFile`d — F-013 held, no
   external files) that `require` / first-unqualified-var-reference replays on demand via
   the existing `driver.runEnvelope`. Expected `-e 1` floor → **~4.8 ms** (with D-140).
   - **F-011 correctness gate (mandatory, same arc):** (a) a build-time check that EVERY
     embedded namespace replays clean (cache_gen already builds each envelope, so this is
     a small extension) — neutralises "load errors move from boot to first-use"; (b) an
     audit of load-time global-table side effects (`defmethod` / `defmulti` / `derive` /
     `extend-type` / `print-method` installs) so no default-path behaviour silently
     depends on a now-lazy namespace. This matches JVM Clojure (core auto-loads; the rest
     you `require`) — the current eager-all gives *accidental* eager semantics that must
     not be silently load-bearing.

3. **Zero-copy in-place bytecode deserialize (Candidate Alt-3).** Redesign the envelope/
   chunk format so chunks are position-independent and the VM reads bytecode arrays +
   constant pools straight from the `@embedFile`'d `.rodata` with no per-chunk
   allocation/copy. Attacks the ~2.1 ms deserialize with **zero pointer-relocation risk**
   (rodata is read-only; the VM builds live heap objects the normal way, so every pointer
   is born absolute-correct through the existing codec). Applied to core's eager chunks
   AND reused by the lazy non-core chunks. Expected floor → **~3.5–3.8 ms** (sub-4 ms),
   no F-004/F-006 surface touched.

4. **Defer Candidate B (heap snapshot) to the generational/nursery-GC unit.** Recorded as
   forward debt. When the moving-GC unit decides the pointer encoding, B's relocation
   rides that unit's already-built slot-rewrite machinery (possibly *free* under
   base-relative encoding), turning B from a premature twice-built ~1 ms-for-max-risk
   gamble into a clean increment. B is NOT pursued now.

Also landed up front (this commit): the env-gated startup profiler
(`src/runtime/startup_profile.zig` + coarse marks in cli/runner/bootstrap), the campaign's
cold-start measurement instrument — off by default, a single null-check on the hot path
when unset (a <10 ms process is invisible to `sample`, so in-binary marks are the only way
to attribute the floor).

## Consequences

- **Sub-4 ms cold floor reachable without opening the heap-relocation correctness surface.**
  The ~3.4 ms exec/linker/page-fault residual becomes the ceiling; further floor work is
  the binary-size axis (D-515: smaller binary → fewer first-touch faults), not bootstrap.
- **Lazy-ns discharges the eager-comprehensiveness-vs-size/startup standing tension** and
  caps the growth the spec.alpha/contrib sweep would otherwise add to every startup.
- **A new correctness contract**: the eager set is a deliberate, audited boundary, and a
  build-time per-ns replay-clean gate guarantees no lazy namespace ships broken. The
  F-011 side-effect-visibility audit is a one-time cost paid in step 2.
- **Alt-3 makes the envelope format load-bearing/rigid** — a chunk-layout change becomes an
  on-rodata-format change. Accepted: the format is already AOT-embedded; the future JIT
  (ADR-0200) operates on a different layer.
- **B's deferral is recorded forward debt**, explicitly co-owned with the moving-GC unit,
  so it is not lost and not built prematurely.

## Alternatives considered

The devil's-advocate red-team output (fresh-context subagent, facts checked against the
named sources) is reproduced verbatim. Its verdict drove the Decision above — in
particular the inversion of the industry-survey front-runner (Candidate B) into a
deferred, GC-coupled increment, and the elevation of Alt-3 (zero-copy deserialize) as the
correct partner for lazy-ns.

> **Leading finding.** Candidate B (build-time heap snapshot) is not a clean fit for this
> codebase as currently shaped. The GC reaches live objects through TWO mechanisms —
> `root_set.enumerate` (small fixed root set) and per-tag *trace* functions
> (`tag_ops.tag_trace_table`). A trace fn answers "what does this object point TO" for the
> mark phase; it does not hand you the ADDRESS of the slot holding the pointer.
> Relocation needs the latter. So B requires building a SECOND, parallel per-tag
> *relocate-slot* table that does not exist today, ~doubling the per-tag maintenance the
> trace table imposes; every one of the 64 possible heap tags must implement BOTH or
> silently corrupt the snapshot.
>
> **Alt 1 (smallest-diff): lazy-namespace (A) + D-140, core stays eager-bytecode.** No
> value-representation coupling, no relocation table, zero NaN-box correctness surface;
> the only option needing no pointer-layout understanding. Largest single win (3.6 ms) for
> the dominant real case. Risk: deferred load-time side effects (`defmethod`/`derive`/
> `extend-type`/`print-method` into global tables invisible until the ns is required) —
> an F-011 hazard (JVM Clojure is equally lazy, but cljw's single-blob gave accidental
> eager semantics users may depend on); and load errors move boot→first-use, mitigated by
> a build-time "every embedded ns replays clean" gate. Respects all F-NNN.
>
> **Alt 2 (finished-form-clean): snapshot CORE's heap only (B scoped to core) + lazy
> bytecode the rest, base-relative pointer encoding internal to the image.** Snapshotting
> all 29 ns is wasted — you relocate 1148 forms a one-liner never dereferences. Scope the
> snapshot to always-needed core (relocation table ~5× smaller, correctness surface ~5×
> smaller); the un-snapshotted 79% costs ZERO at startup (lazy). A and B-scoped-to-core
> are COMPLEMENTARY (disjoint cost: core replay vs non-core replay). Risk: inherits B's
> relocation surface (smaller, fully build-time-controlled = best case) + `builtin_fn`
> (0xFFFF) payloads are linker-set native addresses needing a V8-style external-reference-
> by-index table (the most error-prone sub-part). Respects F-NNN *if* the external-ref
> table is correct; F-004 respected because base-relative is image-internal (relocated to
> absolute before any runtime read).
>
> **Alt 3 (wildcard): zero-copy in-place bytecode deserialize.** Attacks the 2.1 ms
> deserialize by making chunks directly executable from rodata (no per-chunk alloc/copy);
> vm.eval's 2.5 ms still runs (it legitimately must). Captures most of B's deserialize win
> with NO pointer relocation (rodata read-only, pointers born absolute-correct), no
> external-ref table, position-independent instruction stream (version-lock + interior-
> pointer hazards evaporate). Composes with A's laziness for free. Caps at ~6.3 ms alone /
> ~3.5–3.8 ms combined with A. Most F-NNN-safe option (no F-004/F-006 surface touched).
> Risk: serialize format becomes load-bearing/rigid; possible over-invest if the JIT
> replaces it.
>
> **Sequencing verdict.** A and B are complementary, NOT a smallest-diff convenience B
> unwinds — PROVIDED B is scoped to core. B-the-full-29-snapshot subsumes A but is
> wasteful; B-scoped-to-core is complementary and is the finished form. Start with A (it
> is independently the largest win, lowest risk, and a PREREQUISITE for clean B since B
> only makes sense once non-core is lazy). A-before-B is the correct dependency order, not
> smallest-diff bias. The smell to avoid: shipping A then declaring victory at ~4.8 ms
> without ever doing core's snapshot (Progress-pressure) — OR doing full B for a ~1 ms win
> against a 3.4 ms wall (prestige over measurement).
>
> **NaN-box relocation correctness.** "Derive the relocation table from the GC's precise
> pointer map" is NOT sound as stated: (1) the trace table yields referent VALUES, not
> mutable SLOT addresses — a separate per-tag relocate table is needed; (2) roots in
> Zig-side structs off the GC heap (`Var.root`/`.meta`/`.watches`, namespace metadata in
> `infra_alloc`) need relocation but are reached by the root walker, not the heap trace —
> the relocation set is strictly LARGER than the GC's heap trace; (3) `builtin_fn` (0xFFFF)
> payloads are 48-bit linker-set native pointers, not heap pointers — poison unless
> resolved via an external-reference-by-index table; (4) payload is `addr>>3` (8-byte
> aligned) — delta must be a multiple of 8 and mmap base ≥ 8-aligned (page alignment gives
> this, but it is an invariant the loader must ASSERT). A single missed pointer = silent
> heap corruption with no fault. Relocation is achievable but NOT by reusing the GC trace
> map.
>
> **Version-lock.** Largely a non-issue (snapshot embedded in the same binary that consumes
> it — a rebuild regenerates both halves). The real hazard is `cache_gen` (host build tool)
> vs runtime REPRESENTATION SKEW: a heap snapshot encodes in-memory layout, so if cache_gen
> is built for the host but the runtime ships for a different target (Wasm/x86_64/arm64)
> with different padding/pointer-width/endianness, the snapshot is wrong. Bytecode replay
> (A/Alt-3) is immune (target-neutral indices); heap snapshot (B/Alt-2) makes
> cache_gen-target == runtime-target a hard, multiplicative build-matrix invariant.
>
> **Is ~3.4 ms exec/page-fault the real ceiling?** Mostly yes — and it materially weakens
> full B. After A+D-140 ≈ 4.8 ms; after Alt-2 ≈ 3.5–3.8 ms. The residual is `fork/exec` +
> page faults on a multi-MB static binary, which no bootstrap-architecture change
> addresses. B's marginal win over A is ~1 ms (core's replay share), below `fork/exec`
> noise, bought with the entire relocation correctness surface + build-matrix skew. Get
> core's last millisecond via Alt-3's zero-copy deserialize, not heap relocation.
>
> **Co-design B with the moving GC?** Yes — and that is a strong argument to defer B now.
> A generational/nursery GC that moves objects must already solve "rewrite every pointer
> slot when an object moves" = the identical machinery B needs, and may adopt base-relative
> encoding that makes snapshot relocation FREE. Building B now against the non-moving GC =
> building it twice or a throwaway that base-relative encoding unwinds. A and Alt-3 are
> GC-independent and ship now.
>
> **Recommended sequencing:** (1) D-140 footer-seek (−1 ms, zero risk). (2) Lazy-namespace
> bytecode (−3.6 ms common case) + the build-time replay-clean gate + the F-011 side-effect
> audit → ~4.8 ms (meets sub-5 ms). (3) Zero-copy in-place deserialize (−2.1 ms, no pointer
> risk) → ~3.5–3.8 ms (sub-4 ms). (4) Defer heap-snapshot to the GC unit (forward debt).
>
> **The one thing that makes this a mistake:** chasing the ~1 ms B targets while the
> ~3.4 ms wall makes it invisible, paying with a silent-heap-corruption surface + a
> per-target build-matrix lock — driven by the survey's prestige ("SBCL/V8/GraalVM all
> snapshot, so we should") instead of the measurement, which says the impressive answer
> buys an imperceptible millisecond at the worst-testable risk.

The main loop's choice WITHIN the F-NNN envelope (the subagent's recommendation is not
binding): adopted the recommended sequencing in full. The Decision diverges from the
subagent only in emphasis — it treats Alt-2 (core-scoped snapshot) as the same deferred-B
increment co-owned with the GC unit (step 4), rather than a near-term step, because its
relocation surface is the GC unit's to build.
