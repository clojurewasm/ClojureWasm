# ADR-0173 — Envelope format v7: executable wire instructions (zero-copy), lazily-materialized constant pool, flate-compressed lazy regions

- **Status**: Proposed → Accepted (2026-07-16; DA fork folded verbatim below —
  its four required changes are all adopted in this Decision)
- **Driven by**: D-517 (zero-copy in-place deserialize, ADR-0162 step 3 — the
  ~2.1 ms deserialize half of the cold floor) **co-decided with** ADR-0172 L2
  (embedded-data size lever: −0.9〜1.1 MB) per ADR-0172's "one format decision,
  not two". Step-0 survey: `private/notes/D517-envelope-survey.md` (+ Step 0.6
  amendments).
- **Relates to**: ADR-0034 (format-version policy: decoder-only permanent
  compatibility + `docs/spec/formats/<version>.edn` archive), ADR-0118 (VM
  error locations — per-instr line:col on compiled chunks; amended by this ADR:
  AOT chunks gain real `source_file` labels), ADR-0162/0163 (cold-start
  architecture / region blob), ADR-0172 (size SSOT), D-515, F-004 (NaN-box law
  — no raw Value archiving), F-006 (heap Values built at runtime), F-011/F-012
  (dual-backend oracle green per commit).

## Context (measured, 2026-07-16)

- Blob 698,159 B / 31 regions; eager 434 KB (62%), lazy 264 KB. 28,637 eager
  instructions decode element-wise 3 B wire → 12 B memory (alloc + copy).
  Constants dominate chunk bytes (977 KB of 1.17 MB decoded); instrs are
  135 KB — so the pool, not the instr copy, is likely the bigger half of the
  2.1 ms. Per-step attribution is mandatory during the arc
  (`CLJW_PROFILE_STARTUP=1`).
- **42% of the blob (~294 KB) is duplicate interned-name encoding**: 15,907
  interned-name constant occurrences, only 3,342 unique (`var
  clojure.core/list` ×1,141). Net size win after pool+refs bookkeeping
  ≈ −230 KB (u32 refs = 63.6 KB + unique pool ≈ 60 KB replace ~294 KB+uniques
  of inline encoding). Dedup also cuts intern/hash calls ~5×.
- 97.7% of operands < 128, **but** varint decoding forces a copy — it
  structurally conflicts with zero-copy, and flate covers the wire-size win
  for the lazy half.
- `@embedFile` guarantees alignment 1; in-memory `Instruction` is auto-layout
  12 B (opcode u8 / operand u16 / line u32 / column u16); AOT chunks always
  carry line=0 col=0 (ADR-0118).
- **`readValue` precondition (DA-verified, load-bearing)**: the var_ref arm
  (serialize.zig:455) requires the namespace to ALREADY exist at decode time;
  type_descriptor likewise requires the defining chunk to have RUN. Today this
  is guaranteed only by interleaved chunk-by-chunk decode+run. Any design that
  decodes all constants up front breaks it (or, "fixed" by forward-creating
  namespaces, becomes an F-011 regression: `(find-var 'clojure.set/union)`
  must fail before `(require 'clojure.set)` as in clj).
- flate: whole-blob decompress measured 0.46 ms (~0.3 ms for the eager 434 KB);
  lazy regions decompress only on `require`; `.clj` sources 451 KB → ~125 KB.
  Zig 0.16 `std.compress.flate` direct-mode recipe verified against the pinned
  std (fixed reader → `.raw` container → `readSliceAll` into an exact
  `uncompressed_len` buffer; no window buffer, no hidden alloc).

## Decision

1. **WireInstr — the only instruction representation the VM executes.**
   4-byte `extern struct { opcode: u8, reserved: u8, operand: u16 LE }`.
   `reserved` MUST be 0 and is validated at load (corruption tripwire +
   forward space; a u24 `operand_ext` was considered — operand-space pressure
   exists (`DEF_NAME_IDX_MAX` 13-bit, fused-op 8-bit packing) but has no
   measured need yet). `BytecodeChunk.instructions: []const WireInstr` with a
   parallel `locs: ?[]const InstrLoc` sidecar.
   **Split-at-finalize (DA recommendation adopted)**: the compiler's
   build-time representation KEEPS the 12 B loc-carrying `Instruction`, so
   emit/patchJump/peephole/fusion rewrites carry loc atomically with no
   lockstep hazard; `finalize` performs the one split into
   `[]WireInstr + []InstrLoc`. Guards: (i)
   `assert(locs == null or locs.?.len == instructions.len)` at finalize; (ii)
   a NEW e2e asserting exact line:col of a VM error raised AFTER a fused
   compare-branch and after a peephole-modified region (the diff oracle
   compares values, not error locations — it does NOT cover this); (iii) the
   C1 representation change is A/B'd in isolation (protocol below) with an
   explicit revert trigger.
2. **Zero-copy over aligned bytes; ONE decoder.** Aligned embed wrapper
   (comptime copy into `align(8)` rodata) + the serializer pads each chunk's
   instr section to 4-byte offsets from blob start;
   `deserializeChunkInPlace` slices instrs via `bytesAsSlice` after a linear
   **opcode-validation scan** (`WireInstr.opcode` stays raw u8; the scan
   preserves the `DeserializeError` fail-closed contract — critical for CLJC
   user files, where reinterpret-without-validation would turn a bad byte into
   dispatch-time UB/panic). Endianness: `comptime assert(little)` — the dead
   non-LE runtime fallback is NOT kept (all shipped targets are LE;
   an unreachable fallback is the permanent-dead-path shape the project
   forbids). The copying decoder survives the arc only until C3′ replaces its
   callers, then is deleted. Byte sources are three, one code path: rodata
   (eager), `rt.load_arena` (lazy decompressed), and the **CLJC artifact
   payload read into a kept-alive 4-aligned session buffer** (fn constants
   capture their chunks — the buffer must outlive them; audited in C3′).
   Ownership: in-place chunks are borrowed views + per-chunk mutable side
   arrays (`call_sites` cache); the tree_walk.zig:401 freeChunk recursion is
   audited in C3′ and deleted where the borrowed shape makes it moot.
3. **Constant pool — lazily-materialized name-slots (DA-corrected shape).**
   The pool section stores **tag + name bytes** (deduped); the runtime pool is
   a slot array (`[]?Value`-shaped) where a slot materializes through the
   EXISTING `readValue` arms on first reference by a decoding chunk — this
   preserves resolution timing exactly (the first referencing chunk resolves
   precisely when today's inline copy would have; 2nd+ duplicates memoize to
   the same interned Value, observationally identical), keeps the ~5×
   intern/hash dedup and the size win, and avoids eagerly compiling pooled
   regexes for never-required lazy namespaces. Pool refs are **u32**
   (boring-safe; no overflow class for `cljw build` user payloads — a u16
   variant would need a fail-closed `PoolOverflow`; the 32 KB delta is not
   worth the failure mode). GC rooting: interned symbols/keywords need no
   root; pooled gc-managed Values (strings, regexes) make the slot array a
   published root — one root slot + `GC-ROOT:` marker + `.dev/gc_rooting.md`
   row, tracing filled slots only. Artifact payloads carry their own
   self-contained pool.
4. **Flate lazy regions + `.clj` sources** (`.raw` container + explicit
   `u32 uncompressed_len` per compressed region — raw has no framing; MUST in
   the spec). Each lazy region compressed individually (per-region beats a
   super-block: first `require` dirties only its own region, sub-0.1 ms each;
   the flate-window ratio loss across small regions is a few KB — noise).
   Decompressed into `rt.load_arena` on `require`; the same in-place reader
   runs over the arena buffer. The eager core region stays uncompressed for
   zero-copy (the compress-eager-too alternative is Rejected below WITH its
   arithmetic, per the DA). Raw `.clj` sources compressed with
   decompress-on-demand handles (consumers: error `SourceContext` render,
   `cljw build` re-envelope, `embeddedResolver`; `cache_gen` host tool keeps
   raw inputs). CLJC artifacts do NOT gain a compression flag in v7 (no
   measured need; user-local files).
5. **v7 rides three latent fixes**: `has_handlers` serialized (today it
   defaults true on AOT chunks → no bootstrap fn is ever frame-flattened; the
   *consumer flip* is its own commit, C6′, with oracle+bench attribution),
   `source_file` preserved (AOT chunks stop reporting "unknown" — a one-line
   ADR-0118 amendment: labels improve, line stays 0), inner `fn_val` chunks
   stop repeating magic+version.
6. **Rejected** (each with its arithmetic):
   - **Varint instruction stream**: 97.7% of operands < 128, but decode = copy;
     structurally anti-zero-copy; flate covers the lazy wire size anyway.
   - **Compress the eager region too** (DA Alt 3): kills the whole alignment
     apparatus and saves ~360 KB more binary, but costs ~+0.3 ms cold start
     every boot and converts 434 KB of clean, evictable file-backed rodata
     into dirty anon arena pages. D-450/D-517's floor axis outranks the
     residual size delta here — and the alignment apparatus is a one-time
     format cost, not a standing tax. Revisit only if ADR-0172's embedded-data
     budget line is breached after C5′.
   - **rkyv-style object-graph archiving / mmap-ELF container**: F-004/F-006 —
     heap Values are never archived as bits (the whole D-517-vs-heap-snapshot
     risk story, ADR-0162).
   - **Keeping pre-v7 decoders**: ADR-0034 — archive the spec
     (`docs/spec/formats/7.edn`), not the decoder.
   - **Eagerly-decoded `[]Value` pool** (the survey's original §5(ii) shape):
     breaks `readValue`'s findNs/already-ran preconditions; the
     forward-creating-ns "fix" is an F-011 regression. Replaced by the
     lazy-slot shape in Decision 3.
   - **Non-LE runtime fallback decoder**: unreachable on every shipped target
     = permanent dead path; `comptime` assert instead.

Projected: embedded data 1.59 MB → ~0.9 MB in-binary (ADR-0172 budget line
re-sets to 1.0 MB on C5′); eager deserialize cost mostly eliminated (instr
copy gone + ~5× fewer interns); cold floor toward sub-4 ms. Both claims are
measured per-commit (protocol below), not asserted.

## Revision history

- **2026-07-16 (C1 landing)**: Decision 1's "opcode stays a raw u8, dispatch
  converts via `op()`" was **measured at +5-6% on fib/arith** (the
  per-dispatch `@enumFromInt` ReleaseSafe validity check). Amended:
  `WireInstr.opcode` is the **typed `Opcode` field** (enum(u8), defined
  layout, extern-legal) so dispatch reads it directly; untrusted input is
  validated by a **raw-byte scan BEFORE any `[]WireInstr` view is formed**
  (C3′), so an invalid enum value never materializes in a typed slice —
  the fail-closed `DeserializeError` contract is unchanged. With the typed
  field the C1 A/B is within noise (fib 1.02±0.11, arith 1.01±0.07 and
  1.03±0.11 order-swapped, 30 runs hyperfine -N ReleaseSafe; sieve /
  map_filter_reduce neutral) — the revert trigger does not fire. Guard e2e
  `phase16_vm_error_loc_sidecar` (exact 5:6 after a peephole-elided region +
  fused compare-branch) landed with C1.

- **2026-07-16 (C2′ landing — the single v7 wire cut)**: serializer+decoder
  emit/read final v7 (4B WireInstr wire, 4B-aligned instr sections via
  chunk-body padding + 8B-aligned region starts, `source_file` +
  `has_handlers` serialized, headerless nested fn-method chunks,
  `pool_ref` 0x11 + blob-level shared pool / payload-inline pool).
  Spec archived at `docs/spec/formats/1.4.0.edn` INCLUDING the v4-v6
  backfill (three earlier bumps had violated the ADD-ONLY archive policy —
  caught by this arc). **Measured**: blob 698,159 → 544,909 B (−22%, pool
  dedup alone); shipped binary 8,731,096 → 8,583,352 B (−148 KB); eager
  `runEnvelope` 6,123 → 4,190 µs (−32%) — the pool cuts startup BEFORE
  the C4′ memoization even lands. Consumer flip (`has_handlers` flatten)
  remains C6′; the decoder still copies instr arrays (C3′ makes them
  in-place).

## Measurement protocol (mandatory, per commit)

- VM-hot A/B for C1 (representation change, isolated):
  `bash bench/run_bench.sh --quick --bench=<name>` (hyperfine, ReleaseSafe
  only — ADR-0132) across fib_recursive / arith-recur loops / sieve; bar:
  no regression beyond noise (σ < 5%). **A C1 regression REVERSES the split**
  (loc returns inline; the wire can still be 4 B with a load-time widen —
  the wire win decouples from the in-memory gamble).
- Startup attribution for C2′/C3′/C4′/C5′: `CLJW_PROFILE_STARTUP=1` before/
  after each commit; the deserialize line must show the claimed step-wise
  drops (and the flate term appears honestly in C5′).
- Size: `scripts/binary_size_report.sh` before/after C5′; ADR-0172 budget
  table + `size_claims` README figure updated in the same commit.

## Sequencing (single wire cut; every commit oracle + smoke green)

- **C1** — representation split at finalize: build-time `Instruction` stays;
  `BytecodeChunk` becomes `[]const WireInstr` + `locs` sidecar; VM dispatch
  reads the 4 B form. No wire change. A/B bench + new error-loc e2e.
- **C2′** — **the one v7 wire cut**: serializer emits final v7 (padded
  WireInstr section + pool section + `has_handlers` + `source_file` + inner
  header drop + per-region `uncompressed_len` slots); deserializer reads all
  of it (may still copy instrs and materialize pool slots per-chunk at this
  commit). `docs/spec/formats/7.edn` archived HERE, once. CLJC artifacts are
  v7-coherent from this commit on — no mid-arc cross-binary window.
- **C3′** — in-place instr reading (rodata + kept-alive CLJC buffer + arena;
  opcode-validation scan; freeChunk recursion audit/deletion). No wire change.
- **C4′** — lazy pool slots wired as the constants path; intern-dedup
  measured. No wire change.
- **C5′** — flate lazy regions + `.clj` handles (ADR-0172 L2 lands; size
  numbers + budget update). Container-level change only.
- **C6′** — `has_handlers` consumer flip (frame-flattening for handler-free
  AOT fns) — VM behavior change, own oracle + bench attribution.

## Alternatives considered (DA fork, 2026-07-16 — verbatim)

> ## Leading entry (mandated): F-NNN compliance of the finished-form-clean option
>
> **No alternative below requires violating any F-NNN.** All three shapes stay
> inside F-002/F-004/F-006/F-011/F-012/F-013 and ADR-0034's decoder-policy.
> However, one part of the **draft itself is an F-011 hazard as currently
> worded** — the constant pool "decoded ONCE at startup into `[]Value`"
> (survey §5(ii), draft item 3). See critique (b): eager pool materialization
> of `var_ref`/`type_descriptor` entries either **hard-fails at load**
> (checked against `readValue` :455 — `env.findNs(ns_bytes) orelse return
> DeserializeError` requires the ns to already exist, which today is
> guaranteed only by interleaved chunk-by-chunk decode) or, if "fixed" by
> forward-creating namespaces, **changes observable semantics**
> (`(find-var 'clojure.set/union)` before `(require 'clojure.set)` must fail
> as in clj). The fix is inside the envelope (lazily-materialized pool slots),
> not an F-NNN amendment — but the ADR text must change before acceptance.
>
> ## Alternative 1 — smallest-diff: "pool + flate + latent fixes, NO WireInstr
> / NO zero-copy"
>
> Land C3 (constant pool, as name-bytes with per-chunk resolution), C4 (flate
> lazy + .clj), C5 (has_handlers/source_file/inner-header-drop) — and skip the
> instruction-representation change entirely.
>
> - Better: zero touch on the VM's hot representation; zero ADR-0118 risk;
>   captures the measured majority of both wins (constants = 977KB of 1.17MB
>   decoded vs instrs 135KB; the instr copy is plausibly 0.3-0.5ms of the
>   2.1ms, not half).
> - Breaks: D-517's named deliverable stays open; 12B→4B icache + the last
>   ~0.3-0.5ms forfeited. Not recommended on diff-size grounds (the
>   smallest-diff pole); its one legitimate use: if the C2 A/B shows the instr
>   half < ~0.3ms, Alt 1's scope IS the measured shape.
>
> ## Alternative 2 — finished-form-clean: "one representation, one decoder,
> no fallback"
>
> The compiler emits WireInstr directly (or split-at-finalize); DELETE the
> copying decoder (comptime LE assert, no runtime fallback — a fallback with
> no reachable caller is the permanent-dead-path shape the project forbids);
> the CLJC artifact path becomes a lifetime rule (kept-alive 4-aligned
> session buffer, same in-place reader), not a second decoder; ownership
> unifies (chunks always borrowed views + arena side arrays; the
> tree_walk.zig:401 freeChunk recursion is deleted, not worked around).
>
> - Better: no dual-decoder bitrot; no C1-then-C2 half-supersede; one codec
>   for blob + artifact; one answer to "what is a chunk in memory".
> - Costs: compiler emit/patchJump/peephole surgery in the same arc;
>   `CallSiteEntry` mutable cache split into a side array; loses hypothetical
>   big-endian support (no F-NNN requires it). **Recommended over the draft's
>   shape** — the "retain the copying decoder as fallback" is the
>   Smallest-diff bias wearing a portability costume.
>
> ## Alternative 3 — wildcard: "compress EVERYTHING; one bulk decompress into
> an aligned arena; in-place over the arena"
>
> Flate the eager region too (~72KB embedded vs 434KB), decompress at boot
> (~0.3ms) into an 8-aligned session arena, run the same in-place readers.
>
> - Better: kills the ENTIRE alignment problem (no aligned-embed trick, no
>   serializer padding, no bytesAsSlice asserts); one lifetime story; ~360KB
>   more binary shrink (embedded data → ~0.5-0.6MB); still satisfies D-517's
>   letter (no per-chunk alloc/copy).
> - Breaks: +~0.3ms cold start every boot (floor ~3.8-4.1 instead of
>   ~3.5-3.8); +~280KB dirty anon RSS at boot vs clean evictable rodata; the
>   profiler gains a fixed decompress term. A genuine trade the ADR must
>   decide WITH numbers, not dismiss.
>
> ## (a) WireInstr 4B + parallel locs
>
> The `_pad` byte: spec it as reserved-MUST-be-0 validated at load; note the
> u24 operand-ext consideration (operand-space pressure exists:
> DEF_NAME_IDX_MAX 13-bit, fused-op 8-bit packing) without adopting it.
> **The real ADR-0118 risk is peephole/fusion lockstep**: locs as a second
> array that every emit/fusion/peephole must mutate in lockstep; the silent
> failure is locs off-by-N after a stream-shrinking pass — errors report a
> WRONG line, which no existing test distinguishes. Guards: len-assert at
> finalize + every pass exit; a NEW e2e asserting exact line:col AFTER a fused
> compare-branch and a peephole-modified region; say explicitly the diff
> oracle does NOT cover error locations. **Split-at-finalize removes the
> lockstep hazard entirely** (build-time keeps 12B; only the finalized form
> splits) — may be the strictly better shape the draft never considers.
> The icache claim is a premise, not a measurement — C1 must be A/B'd in
> isolation (`run_bench.sh --quick`, hyperfine, ReleaseSafe, σ<5% bar) with
> an explicit revert trigger (loc back inline; wire stays 4B with load-time
> widen — decouples the wire win from the in-memory gamble).
>
> ## (b) Constant pool — the draft's weakest section
>
> Resolution timing is NOT preserved by the survey's design (verified against
> readValue :455/:486 — findNs precondition + "defining chunk has already
> run"). Interleaved decode+run supplies today's invariant; a boot-time pool
> decode breaks it; forward-creating namespaces is an F-011 regression.
> **Finished-form repair: pool = tag + name bytes; runtime pool =
> lazily-materialized slot array** filled through the EXISTING readValue arms
> on first reference — preserves timing exactly, keeps the 5× dedup (each
> unique name read+hashed once), keeps the size win, avoids eagerly compiling
> pooled regexes for lazy-only namespaces. GC rooting: interned syms/kws need
> no root; pooled STRINGS are gc-managed → slot array = published root (nil-
> init, trace filled only, GC-ROOT marker + gc_rooting.md row).
> Arithmetic: u32 refs = 15,907×4 = 63.6KB + unique pool ≈ 60KB replace
> ~294KB+uniques → **net ≈ −230KB, not −294KB**. u16 halves ref cost but
> needs fail-closed PoolOverflow for cljw-build user payloads; u32 is the
> boring-safe pick. Show the arithmetic in the ADR either way.
>
> ## (c) flate
>
> The 0.46ms local measurement on the pinned 0.16 std outranks regression
> folklore; pin the direct-mode recipe (fixed reader → .raw → readSliceAll
> into exact uncompressed_len; no window buffer) and store u32
> uncompressed_len per region (raw has no framing) as a spec MUST.
> Per-region beats super-block (first require dirties only its region;
> window-ratio loss across small regions = a few KB = noise). The
> eager-compression question IS Alternative 3 — carry its arithmetic in
> Rejected. **RSS clean-vs-dirty**: uncompressed rodata is file-backed clean
> evictable; arena-decompressed bytes are dirty anon forever (load_arena is
> session-lifetime by design; fns capture their bytecode). Compressing raw
> .clj is near-pure win (dirty only on cold error-render); worst-case
> all-lazy-required ≈ +264KB dirty = 1% of the <25MB idle target — write the
> number; today's copying decoder already builds >wire-size dirty structures,
> so in-place-over-arena is RSS-neutral-to-better vs today.
>
> ## (d) Sequencing — one thing genuinely backwards; the version question has
> a sharp answer
>
> C2→C3 as two wire-changing commits under one "v7" breaks the ADR-0034
> archive discipline (spec written twice or describing a one-commit layout)
> and CLJC cross-binary integrity (two artifacts both saying "7" disagreeing
> on the constants section). For the @embedFile'd blob the version genuinely
> does not matter (regenerated every build; self-consistency assert only);
> for CLJC it does. **Fix: format cut ONCE (C2′ emits+reads final v7),
> migrations after (C3′ in-place, C4′ lazy pool, C5′ flate container, C6′
> flatten flip)** — every post-C2′ commit is wire-stable and independently
> A/B-attributable. Which v7 parts reach CLJC: WireInstr layout+padding,
> per-payload pool, has_handlers/source_file, inner-header drop — ALL;
> region-blob flate + .clj compression — NOT (container level). Recommend no
> artifact compression flag in v7. Pin the artifact in-place story (4-aligned
> kept-alive buffer; unaudited by the survey — audit in C3′).
> **Latent hazard for C3′: opcode validation** — today's copy loop validates
> via std.enums.fromInt; bytesAsSlice + @enumFromInt dispatch would turn an
> invalid byte into safety-checked UB/panic instead of DeserializeError; for
> CLJC user files it must fail closed. Keep opcode raw u8 + one linear
> validation scan at load. Riders: flipping the has_handlers CONSUMER is its
> own commit (VM behavior change); ADR-0118 gets a one-line amendment
> (source_file labels improve).
>
> ## Verdict
>
> The draft's core skeleton is sound and F-NNN-clean, but four changes are
> required before Accepted: (1) lazily-materialized pool slots (the hardest
> finding, verified in code); (2) single wire cut before consumer migrations;
> (3) adopt Alt 2's decoder story at least partially (kill the dead non-LE
> fallback; kept-alive in-place artifact path; consider split-at-finalize to
> erase the locs lockstep hazard); (4) numbers where premises are (C1 A/B
> with revert trigger; Alt-3 arithmetic + clean/dirty RSS analysis in
> Rejected). None of these blocks the unit; all fit the F-NNN envelope.

All four required changes are adopted: Decision 3 is the lazy-slot pool,
the Sequencing is the single-wire-cut order, Decision 2 kills the non-LE
fallback + pins the kept-alive artifact path + adopts split-at-finalize, and
the Measurement protocol + Rejected arithmetic sections carry the numbers.

## Consequences

- The envelope format becomes load-bearing/rigid (accepted by D-517's
  barrier); every future chunk-layout change is an on-rodata-format change
  with a mandatory spec archive.
- The VM's executed instruction representation changes (4 B + loc sidecar) —
  A/B-benched at C1 with an explicit revert trigger; the compiler's build-time
  representation is unchanged (split-at-finalize), so the peephole/fusion
  layer carries no lockstep risk.
- `cljw build` artifacts are v7 from C2′ on; a v6 artifact is rejected by a
  v7 cljw with the standard version error (acceptable per ADR-0034 policy;
  pre-2.0).
- RSS: worst-case all-lazy-required ≈ +264 KB dirty anon (1% of the <25 MB
  idle target); compressed `.clj` render paths dirty at most ~451 KB on cold
  error-render; today's copying decoder already builds larger dirty
  structures per region, so the net is neutral-to-better.
- ADR-0118 amendment (one line): AOT chunks now carry real `source_file`
  labels; per-instr line stays 0 for AOT.

## Affected files

- `src/eval/bytecode/serialize.zig`, `src/eval/backend/vm/opcode.zig` (+ VM
  dispatch), `src/eval/backend/vm/compiler.zig` (finalize split),
  `src/eval/backend/tree_walk.zig` (freeChunk recursion audit/deletion),
  `src/app/builder.zig`, `src/cache_gen.zig`, `build.zig` (aligned embed
  wrapper), `src/lang/bootstrap.zig` (compressed `.clj` handles),
  `docs/spec/formats/7.edn` (new), `.dev/gc_rooting.md` (pool root),
  `.dev/debt.yaml` (D-517), ADR-0172 (revision on C5′), ADR-0118 (amendment).
