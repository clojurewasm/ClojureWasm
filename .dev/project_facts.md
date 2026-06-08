# Project facts — user-declared invariants

> ## ⚠️ THIS FILE IS PROJECT LAW
>
> Every `F-NNN` entry below is **confirmed direction (treat as
> law, not preference)**. The autonomous loop must NOT:
>
> - re-decide an F-NNN to a different shape on its own
> - treat F-NNN as "informational" / "recommended" / "tie-breaker"
> - propose alternatives that violate an F-NNN
> - skip reading an F-NNN at the trigger points below
>
> When ROADMAP / ADR / rule text disagrees with an F-NNN, the
> F-NNN wins. Edit the ROADMAP / ADR / rule to match (this is
> the **only** allowed reconciliation; never the reverse).
>
> **Priority order (highest first)** for the autonomous loop:
>
> 1. `project_facts.md` (this file) — user-declared invariants
> 2. ROADMAP — engineering plan
> 3. ADRs + rules — implementation decisions
> 4. principle.md heuristics — smell sensors, depth selection
> 5. AI judgement — fills in everything the above leave open
>
> Anything at level N may be edited only to align with level
> N-1 (or above). Level 1 (F-NNN) is edited **only** by user
> direction in chat + a new `Revision history` entry on the
> affected F-NNN; the loop never amends F-NNN on its own.

## What this file is for

ClojureWasm v1's ROADMAP / ADRs / rules describe the
*engineering decisions* the project has committed to. This file
captures the **invariants the user has declared** that those
documents may not yet reflect — facts the autonomous loop must
treat as load-bearing even when ROADMAP / ADR text appears to
admit other readings.

The autonomous loop reads this file:

- At cold-start (handover Next files to read, item #3)
- As part of every Phase entry's reading list (CLAUDE.md Step 1a)
- Whenever a planned change touches the topics any F-NNN covers
- When the Devil's-advocate subagent is briefed — **the subagent
  must not propose alternatives that violate any F-NNN**

This file is **append-only history** — entries are dated and
never silently rewritten. A later fact that supersedes an
earlier one is added as a new entry with a `Supersedes: <id>`
line; the earlier entry stays, annotated `Superseded by: <id>`.

## How an F-NNN entry is created or amended

**Creation** (new F-NNN):

1. User declares a project-level invariant in chat (verbatim
   quote captured below).
2. Loop captures the declaration as the next `F-NNN` entry with
   verbatim quote + "What this changes for the loop" + cross-
   references. Initial `Status: confirmed` is set at creation.
3. User reviews end-of-session (or in the next session via
   project_facts at handover read).

**Amendment** (modify an existing F-NNN):

1. **User direction in chat is required** — the loop never
   amends an F-NNN on its own initiative.
2. The original F-NNN entry's body is updated and an entry is
   appended to its `Revision history` block (date + summary of
   change + user's verbatim quote).
3. If the change is large enough to be a different fact,
   create a **new F-NNN with `Supersedes: F-<old>`** and mark
   the old entry `Superseded by: F-<new>` instead of editing.

**Pre-commit gate**: `scripts/check_facts_immutable.sh` blocks
commits that modify an F-NNN body without either (a) a matching
`Revision history` update in the same commit + a
`Project-facts-amend: F-NNN` line in the commit message, or
(b) the explicit creation of a `Supersedes:` chain.

---

## F-001 — zwasm v2 integration is unavoidable

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-23 (user chat).
**Verbatim**: 「このプロジェクトがzwasmと連携するのは確実です。zwasm
v1は今それなりの完成度ですが、zwasm v2と連携するつもりです。
$My/zwasm_from_scratchはまだ開発途上ですが、wasm FFIは欠かせない
要素だということは自覚してください。また、zwasmはそれ自体がJITや
メモリ管理の機能を持っています」

**What this changes for the loop**:

1. ADR-0006 frames Wasm FFI as "deferred to Phase 16 via Pod
   boundary". The Pod-boundary framing remains the **default
   protocol shape**, but the inline-vs-Pod choice **is not closed**.
   Phase 16 entry must re-open it with the user (D-036).
2. ADR-0006 amendment 1 (NaN-box slot release for big_int /
   ratio) assumed Pod-boundary. If Phase 16 chooses inline
   NaN-box Values, those slots cannot be reclaimed — Phase 16
   must mint fresh slots, co-ordinated with D-027 (NaN-box
   layout 第二世代).
3. zwasm v2 carries its own JIT + GC. cw v2's Phase 5 mark-sweep
   GC and Phase 17 JIT (ADR-0005 3rd backend) **overlap
   territorially**. Phase 16 entry resolves heap-boundary and
   JIT-coordination design (cw-heap vs wasm-heap, JIT handoff).
4. The counterparty is **zwasm v2**, not zwasm v1. zwasm v1 is
   reasonably complete, but cw v2 targets zwasm v2.
   `~/Documents/MyProducts/zwasm_from_scratch/` is the in-progress
   counterparty repo.

**Cross-references**: ADR-0006 amendment 3 (records this fact in
the ADR); debt D-036 (Phase 16 inline-vs-Pod decision); ROADMAP
§9.18 Phase 16 placeholder (Entry debts).

**Revision history**:

- **2026-06-05 (user chat)** — zwasm v2 (`$MY/zwasm_from_scratch`)
  is nearing completion and its **Zig API is now in place**, so it
  can be tried via a **`build.zig.zon` relative-path import**. The
  user directs the loop to **bring the integration spike forward**
  out of its current locked / infinitely-deferred (Phase 16) state
  and **trigger it as the next unit once the current cluster
  completes** — this activates D-037's early-prototype window
  (Phase 8-15) now. This does NOT collapse the Phase 16 full-FFI
  design (D-036 inline-vs-Pod stays Phase 16 territory); it adds an
  early **import-and-smoke spike** ahead of it. **Guardrail (user):
  zwasm v2 is itself under active AI development — the loop MUST NOT
  pin an in-progress state.** zwasm **v2 is used ONLY from the
  `zwasm-from-scratch` long-lived branch of
  `~/Documents/MyProducts/zwasm_from_scratch/`** (user, 2026-06-05).
  The git **tags are zwasm v1 — NEVER pin a tag**, and **zwasm v1 is
  never used or supported.** "Usable point" therefore means *the
  long-lived branch builds + its `scripts/check_zig_consumer.sh`
  passes* (a working-tree / branch-HEAD check, not a tag/version
  pin). The loop keeps the spike behind a build flag so cw v1's
  default gate never depends on zwasm, and backs off + re-defers with
  a dated note (no thrash) if that branch is mid-rewrite. Wired in
  D-037 (trigger) + D-038 (verify-against-repo) + handover Next.
  **Finding-handling policy (user, 2026-06-05): both repos are the
  user's.** Bugs / gaps / usability friction surfaced during wasm
  integration are split by SIDE: a **zwasm-side** issue is RECORDED +
  FED BACK (no cljw-side code change to "work around" it; **never edit
  zwasm code** — feedback is relayed to zwasm via the user) in
  `private/notes/zwasm_v2_feedback.md`; a **cljw-side** issue gets a
  real code fix (root-cause resolution + debt row, not a workaround).
- **2026-06-08 (user chat — pin the `v2.0.0-alpha.1` dogfood tag;
  supersedes the 2026-06-05 "NEVER pin a tag" guardrail).**
  **Verbatim**: 「今、cw v1（ClojureWasmFromScratchのこと）は、相対パスで、
  build.zig.zonとかで動作させていますが、zwasm v2（このPCでは、
  $MY/zwasm_from_scratchの v2.0.0-alpha.1 タグをきったものを指定して
  動かしたいです。」+（デモ堅牢化フェーズについて）「あれ、これ考慮
  できていな、バグっている、未実装だ、ということに気付いたら、
  zwasm_from_scratchおよびClojureWasmFromScratchで修正をしていきます」.
  The user cut
  a deliberate **v2 pre-release tag `v2.0.0-alpha.1`** (commit `3b84fa24`,
  pushed to `clojurewasm/zwasm`) **off the `zwasm-from-scratch` long-lived
  branch, explicitly for ClojureWasm dogfooding** (tag message: *"First
  pre-release from the long-lived zwasm-from-scratch branch for
  ClojureWasmFromScratch dogfooding (alpha = may break; not merged to
  main)"*). cw v1 now consumes zwasm v2 by **pinning that tag** in
  `build.zig.zon` (`url = "git+…/zwasm.git#v2.0.0-alpha.1"` + `hash` +
  `lazy = true`), replacing the prior relative-path branch-working-tree
  import. This **supersedes the 2026-06-05 guardrail "the git tags are
  zwasm v1 — NEVER pin a tag / use only the long-lived branch working
  tree"**: that guardrail's premise (tags are v1; the tree is mid-rewrite
  so any pin captures churn) **no longer holds** — a real *v2* alpha tag
  now exists, cut intentionally as a stable dogfood point, and its content
  is cryptographically pinned by `.hash` (so it cannot drift even as the
  branch moves on). UNCHANGED: zwasm stays `lazy` + `-Dwasm`/`-Dzwasm-spike`
  flag-guarded, so cw v1's DEFAULT build + gate never resolve it (verified:
  full gate 293/0 green with the tag pin, ReleaseSafe build + `zig build
  test` pass). Re-pinning to a later `v2.0.0-alpha.N` tag is a routine
  bump (new tag → `zig fetch` new hash → update `build.zig.zon`), not an
  F-001 amendment. The finding-handling policy (zwasm-side vs cljw-side
  split) from the 2026-06-05 entry stays in force, with the user's
  2026-06-08 addition that **direct edits to `zwasm_from_scratch` are now
  user-authorized** during this interactive demo-hardening phase (the loop
  confirms direct-edit vs record-and-relay per zwasm-touching change).
- **2026-06-08 (user chat — switch to RELATIVE-PATH co-development; two
  consumption modes).** With the demo-hardening security pass now actively
  fixing BOTH repos in lockstep, cw v1 consumes zwasm via a **relative-path
  `build.zig.zon` import (`.path = "../zwasm_from_scratch"`, `lazy = true`)**
  again, NOT the tag pin. **Verbatim**: 「zwasm_from_scratch側のセッションで…
  対応がまとまりました。なので、ClojureWasmFromScratch側の作業にうつります。
  相対パスでのbuild.zig.zonにしたり」+「build.zig.zonは相対パスから読むことが
  でき、まだタグ作らなくてもビルドや実行可能である。作業途中で、
  zwasm_from_scratch側にフィードバック修正したくなることもあると思うので。」
  This formalises **two consumption modes** (not a contradiction — a phase
  selector):
  - **Relative-path = active co-development mode (current).** zwasm's
    `zwasm-from-scratch` working tree is consumed directly, so a zwasm fix is
    picked up immediately and cljw can feed back more findings
    (`security_handover_from_cljw_03.md`…) without tag/fetch churn. This is the
    mode whenever the two repos are being fixed together.
  - **Tag pin (`v2.0.0-alpha.N` + `.hash`) = stable-snapshot / release mode.**
    Used when the integration settles, or for a reproducible CI/release build.
    The `alpha.1` pin landed earlier is NOT wasted — it verified the
    tag-fetch-and-build path works as a snapshot mechanism.
  Switching between the two modes is a routine `build.zig.zon` edit (path ↔
  url+hash), NOT an F-001 amendment. **UNCHANGED:** zwasm stays `lazy` +
  `-Dwasm`/`-Dzwasm-spike` flag-guarded, so cw v1's DEFAULT build + gate never
  resolve zwasm in either mode (the churning relative tree cannot break the
  default gate). The finding-handling split + direct-edit authorization from
  the prior 2026-06-08 entries stay in force.

---

## F-002 — Finished-form cleanliness wins; shipping fast / avoiding rework are second-tier

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-23 (user chat).
**Verbatim**: 「完成した時の綺麗さ、 が何よりも優先されています。
さっさと作る、 手戻りしない、 は二の次です(もちろん少ないに越した
ことはないので事前ロードマップを敷いているが)」

**What this changes for the loop**:

1. **Big surgery (depth 3-4 in `.dev/principle.md`) is the
   default response to a structural smell, not the exception.**
   When the plan misses something, the loop **must** take the
   surgery; "I'll patch it now and refactor later" is the
   Progress-pressure smell and is forbidden in this project.
2. **Finished-form ALWAYS wins over smallest-diff.** ROADMAP P5
   ("smallest-diff first") is not a tie-breaker; it is a
   *secondary preference that applies only when the candidate
   options would each reach the same finished form*. If two
   options reach **different** finished forms, the cleaner
   finished form wins regardless of diff size. Treating
   smallest-diff as a tie-breaker (= "well, they're both
   acceptable, so smaller wins") is the **Smallest-diff bias
   smell** and is forbidden.
3. Skeleton-then-rewrite is endorsed (per
   `permanent_noop_forbidden.md`), but **excessive skeletons
   are a smell** — each skeleton must demonstrably reduce the
   eventual rewrite cost, not enlarge it.
4. Reservations (ADR numbers, NaN-box slots, debt rows promising
   future ADRs) are memos, not contracts. ADR numbers are
   time-ordered (`max + 1` at issue). Treating a reservation as
   binding is the **Reservation-as-bias smell** and is forbidden.
5. **Rework, when it leads to a cleaner finished form, is a
   feature, not a failure.** The loop is not graded on commit
   count or speed; it is graded on the shape of the finished
   form. If a Phase 5-entry ADR cluster requires re-writing
   half of `value.zig` plus a NaN-box layout migration plus a
   GC root-set restructure, **that is the right amount of work
   to do**.

**Cross-references**: CLAUDE.md § Project spirit (top); ADR-0029
→ ADR-0025 rename history; D-021 retirement; principle.md Bad
Smell catalogue (Smallest-diff bias / Reservation-as-bias /
Progress-pressure entries — these are the named smells F-002
generates).

---

## F-003 — Decision-deferral over decision-seizure on structural plans

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-23 (user chat).
**Verbatim**: 「すでにロードマップが将来にわたるまであるのだから、
テーブル予約についてどれくらいありそうかを省略せずにしっかり
想像するフェーズを入れて、 どうするかを決めるのはその担当のとき
にやってください」
+ 「あと、 ついでにディレクトリ構造、 ファイル構造の予測や責務
分離や依存関係でも将来にわたり無理がこないのかを想像・シミュレート
して考えてみて」

**What this changes for the loop**:

1. The loop's job at any task touching a reservation table /
   directory or file structure / responsibility / dependency
   graph is **imagine, record, defer** — not decide.
2. Decisions belong to the owning Phase entry's owner. The
   current loop records the imagination output as debt rows
   scheduled at the owning Phase.
3. This is the antidote to the Progress-pressure smell on
   structural work.

**Cross-references**: principle.md "Structural imagination
phase"; CLAUDE.md Step 0.5 (Phase-entry debt read) + Step 1
(Structural imagination trigger); debt rows D-027 / D-029 /
D-031 / D-032 / D-034 / D-035 / D-036.

---

## F-004 — NaN-box layout 第二世代 = 4 group × 16 sub-type = 64 slot (44-bit pointer)

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-24 (user chat after struct-imagination
research; see `private/notes/struct_imagination_research.md`
525 lines).

**Direction confirmed**: Phase 5 entry lands the NaN-box second
generation as **4 group × 16 sub-type = 64 slot, 44-bit shifted
pointer (128 TB address space)**. Issued as a new ADR
(D-027 candidate) co-issued with the mark-sweep GC + TypeDescriptor
activation. Co-ordinated with `value.zig` split (D-029).

**Why this shape**:

- cw v0 final state = 32 slot with **5 types crammed into the
  `delay` slot via a discriminant byte** (future / promise /
  delay / agent / ref). cw v0 also crammed `ratio` + `big_decimal`
  into a single slot. This was a design surrender that produced
  debug pain. cw v2 refuses the same path.
- cw v2 day-1 26 tags will reach ~45 by Phase 15 (counted in the
  research note). 32 slot is provably insufficient.
- Sub-type bits 3 → 4 cost **zero performance** (decode
  instruction count unchanged; only shift/mask constants change).
  Pointer reduction 45 → 44 bit stays comfortably within the
  user-space VA on all supported platforms (Linux x86_64 /
  aarch64, Mac aarch64, Windows x86_64 — all canonical 48-bit
  user space = 128 TB).
- 64 slot absorbs the day-1 plan + Phase 5-15 additions + the
  newly-imagined types below, with ~10 slots reserve for further
  surprises.

**Types day-1 in the 64-slot plan that the cw v2 ROADMAP did NOT
previously enumerate** (research §1.2):

- **Seq family**: `range` / `LongRange` (chunked range for
  `(reduce + (range 1e6))`), `string_seq` (`(seq "abc")`),
  `array_seq` (`(seq arr)`).
- **Coll family**: `map_entry` (`(first {:a 1})` returns a
  MapEntry, not a vector — `instance?` differs), `sorted_map`
  (`PersistentTreeMap`), `sorted_set` (`PersistentTreeSet`),
  `persistent_queue`.
- **Reader family**: `tagged_literal` (EDN `#my/tag 42`
  round-trip), `reader_conditional` (`#?(:clj …)` for `.cljc`).
- **Wasm family** (inline-tagged, F-001 zwasm v2 integration):
  `funcref`, `externref`. (cw v0 did not slot-promote these; cw
  v2 day-1 plans them because zwasm v2 integration is unavoidable
  per F-001.)

**Indicative slot map** (full table in the research note; the
final placement lands when the Phase 5 ADR draft is reviewed via
the Devil's-advocate subagent):

- **Group A — Hot data + persistent collections** (16 slots):
  string / symbol / keyword / list / vector / array_map /
  hash_map / hash_set + lazy_seq / cons / chunked_cons /
  chunk_buffer + range / string_seq / array_seq / map_entry.
- **Group B — Callables + reader extra** (16 slots):
  fn_val / multi_fn / protocol / protocol_fn + var_ref / ns /
  delay / regex + tagged_literal / reader_conditional / class /
  reified_instance / type_descriptor / host_instance +
  2 reserved.
- **Group C — Mutable + concurrency** (16 slots):
  atom / agent / ref / volatile + future / promise / reduced /
  ex_info + transient_vector / transient_map / transient_set +
  array_chunk / persistent_queue / sorted_map / sorted_set +
  1 reserved.
- **Group D — Numeric + wasm + extension** (16 slots):
  big_int / ratio / big_decimal / array (Java-array compat) +
  wasm_module / wasm_fn / wasm_funcref (inline) /
  wasm_externref (inline) + matcher / tuple / box +
  5 reserved.

**Cross-references**: debt D-027 (the surgery row); D-029
(`value.zig` split, runs co-ordinated with D-027); research note
`private/notes/struct_imagination_research.md` §1, §7; ADR-0012
(amendment 1 currently parks big_int / ratio at slots 29 / 30
of the 32-slot layout — second generation moves them to Group A's
big_int / ratio / big_decimal slots; the amendment-1 placement is
the smallest-diff landing, not the finished form).

**Revision history**:

- **2026-06-05 (user chat — KEEP 64; 128-expansion considered +
  deferred)**: with ~54 slots used and ~10 reserved (the whole 64
  namespace is now populated), expanding to 4 group × 32 = 128 was
  weighed and **deferred**. The expansion is NOT a cheap constant
  change: it needs a 5th sub-type bit, which must come from the
  heap pointer (47→46-bit), but the GC heap is backed by the system
  GPA (`gc_heap.zig` `infra`), so pointers span the full 47-bit VA
  (ASLR/mmap reach the upper half) — a 46-bit (64 TB) encoding would
  corrupt high pointers. Safe 128-expansion therefore requires a
  **reserved-region allocator** (mmap-reserve a region + bump
  within), which is the SAME unlock as future compaction. **Decision:
  stay at 64; revisit (region allocator → 128 + compaction) only if
  slots genuinely run out.** Slot-need for the near term is covered
  WITHIN 64: arrays use the reserved D3 `array` slot; writers
  (`*out*`/`*err*`) are `host_instance` (B13), no new slot. The
  64-slot count + the bit layout are UNCHANGED by this — this entry
  records the considered-and-deferred expansion, not an amendment.
  Detail: `private/notes/layout-gc-decisions-2026-06-05.md`; debt
  D-247.

---

## F-005 — Numeric tower: Clojure JVM surface compatibility, Zig-native internal implementation

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-24 (user chat).
**Verbatim**: 「数値タワーの互換性はあって良いんじゃないか(ただし
見た目や表出する振る舞いだけで内部はZig実装に親和のやり方という認識)」

**Direction confirmed**:

- **User-observable behaviour matches JVM Clojure**:
  `(* Long/MAX_VALUE 2)` → BigInt auto-promote;
  `(/ 1 3)` → Ratio `1/3`;
  `1.5M` → BigDecimal; `(+ 1 1.5)` → 2.5 (double widening);
  `(+ 1/3 1/6)` → `1/2` (Ratio addition).
- **Internal implementation uses Zig stdlib affinity**:
  `std.math.big.int.Managed` for BigInt limbs (already adopted at
  task 4.23); Ratio = `(BigInt, BigInt)` struct with simplification
  on construction; BigDecimal = `(BigInt unscaled, i32 scale)`.
  No re-implementation of arbitrary precision arithmetic — borrow
  the stdlib.
- All three are **heap-allocated** (任意精度 cannot fit in NaN-box
  47 bits). Heap slots assigned in F-004 Group D.
- Promotion is the runtime's job, not the user's: Long overflow
  silently promotes to BigInt (matches `+`); `+'` family (when
  added) throws on overflow.

**Cross-references**: F-004 (Group D slot allocation); ADR-0017
(Allocator strategy — promotion path); debt D-014a (numeric tower
landing target Phase 5); current scaffold
`src/runtime/numeric/big_int.zig` (HeapTag.big_int at slot 29
per ADR-0012 amendment 1 — moves to Group D slot 1 at Phase 5
entry per F-004).

---

## F-006 — GC strategy = mark-sweep + 3-layer allocator (cw v0 inheritance); zwasm v2 heap is separate, cw GC allocator injects into zwasm bookkeeping

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-24 (user chat after research review).
**Verbatim** (paraphrased): 「2 種類に分けてやる系の GC が
mark-sweep GC?これと Arena の組合せが今かな」 +
「(generational) までしなくてもワークしてたような」

**Direction confirmed**:

- **Phase 5 GC = mark-sweep, single generation** (cw v0 path).
  "2 種類に分ける" was the user's interpretation of "mark phase +
  sweep phase" — clarified, not generational.
- **3-layer allocator** continues cw v0's D70 design:
  1. GPA (`infra_alloc`): Env / Namespace / Var / process-lifetime
     storage.
  2. Arena (`node_arena`): Reader Form / Analyzer Node /
     per-program lifetime.
  3. GC allocator (`gc_alloc`): Values (Fn / collections /
     strings / lazy_seq / etc.) — mark-sweep collected, free-pool
     recycled.
- **Generational GC is a future candidate** (ROADMAP §89.2),
  **not Phase 5**. cw v0 reached production maturity without it;
  cw v2 follows the same starting point.
- **cw v0 free-pool optimisation is inherited**: intrusive linked
  list per (size, alignment); demonstrated 3-7x speed-up on
  gc_stress / nested_update benchmarks.
- **cw v0 reflection points to address from day 1**: root-set
  enumeration must cover (a) macro-expansion-time lazy-seq
  realisation paths, (b) ProtocolFn / MultiFn inline caches,
  (c) refer()-borrowed string pointers, (d) closure-captured
  Values in macro callFnVal, (e) valueToForm intermediate trees.
  These five gaps are what cw v0 patched late (D100); cw v2 lists
  them in the Phase 5 GC ADR's "Root sources" section.
- **zwasm v2 integration heap layout** (F-001 + research §2.4):
  cw heap and Wasm linear memory are **separate spaces** that
  co-exist (no unification). zwasm internal bookkeeping (module
  metadata, function table, instance state) accepts a cw GC
  allocator at `Engine.init(allocator)` time, so dual-GC lifecycle
  mismatch (cw v0's D110 issue) does not recur. `wasm_module` /
  `wasm_fn` are cw-GC-managed Values; zwasm metadata lives
  underneath them.

**Cross-references**: F-001 (zwasm v2 integration); F-004 (NaN-box
slots for wasm types); debt D-011 (mark-sweep GC implementation);
debt D-020 (header bit helpers, `cmpxchgLockBits`); debt D-036
(Phase 16 zwasm integration shape — heap-boundary design); ADR-0017
(Allocator strategy); research note §3, §4.

---

## F-007 — Chapter cadence (`docs/ja/learn_clojurewasm/`) is intentionally NOT to be re-produced; archive is permanent

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-23 (user chat, paraphrased as 「参考書作成の
ことであれば、 (しなくていい) というのがわたしの意見として反映
したはず」).

**Direction confirmed**:

- ADR-0025 archived `docs/ja/learn_clojurewasm/0001-0020` + the
  `learn_zig` companion under `docs/ja/archive/`. The user
  explicitly does **not** want the chapter cadence to resume
  unprompted. The autonomous loop must not propose, draft, or
  re-activate the cadence on its own.
- The per-task notes half (`private/notes/<task>.md`) **continues
  to be written** at Step 7 of the per-task TDD loop. These are
  the live record of session intent.
- If a future need for published learning material arises, the
  user signals it explicitly; only then does the loop draft a
  "Resume chapter sequence" ADR.
- `scripts/check_learning_doc.sh` stays at its early `exit 0` —
  the chapter pairing gate is dormant and remains dormant.

**Cross-references**: ADR-0025 (the archive boundary); CLAUDE.md
language policy + code_learning_doc skill description (both
already annotated dormant); `scripts/check_learning_doc.sh`
(early exit); handover.md (chapter cadence dormant line).

---

## Anticipated directory structure (Phase 5–20 imagination)

The full directory tree predicted across Phase 5–20 (per F-003
Structural-imagination phase) lives in
[`.dev/structure_plan.md`](./structure_plan.md). Each Phase
entry's owner consults that file when expanding the §9.<N>
placeholder; decisions on splits / moves / new subdirectories
remain with each owner.

---

## F-008 — zwasm v2 zig_api_design.md (ADR-0109) review record + cw v1 stances

**Status**: `confirmed` — direction of travel is law. Amendable only by user direction + Revision history entry.

**Declared**: 2026-05-24 (user provided zwasm v2 spec; cw v1
reviewed it via this session).
**Source**: `~/Documents/MyProducts/zwasm_from_scratch/docs/zig_api_design.md`
(ADR-0109 Proposed). Full cw v1 feedback note (zwasm v2 への
配信用 draft) lives in
`private/notes/zwasm_v2_feedback.md` (gitignored).

### What zwasm v2 spec gives cw v1 (pixel-perfect integration points)

These spec elements are **load-bearing for cw v1** and must be
treated as fact during Phase 5-15 design (long before Phase 16
entry actually consumes the integration):

| zwasm v2 element                                                                   | cw v1 dependence                                                                                                         |
|------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| §1 Allocator strict-pass (`Engine.init(alloc, opts)`)                             | F-006 cw GC allocator injection の根拠                                                                                   |
| §3.4 "Host alloc and Wasm linear memory are separate by construction"             | F-006 heap-separation 同文                                                                                               |
| §4.1 funcref encoding `@intFromPtr(*const FuncEntity)` + 0 sentinel               | F-004 Group D inline `funcref` slot をビット幅で受け入れる根拠 (ただし要 align(8))                                       |
| §4.3 NaN-boxing-friendly bit ownership (float bit pattern を canonicalize しない) | cw v1 が float slot に NaN-box tag を入れた Value を wasm fn 引数として通せる前提。 spec から削られたら cw v1 設計が破綻 |
| Linker + Instance + TypedFunc pattern (§2-3)                                      | cw v1 が Clojure 側に「wasm/load / wasm/instance / wasm/call」 を露出する設計の API base                                 |
| §3.5 untyped `Instance.invoke(name, args, results)`                               | Clojure dynamic dispatch (signature が runtime まで判明しない) を支える唯一の path                                       |
| Trap 12 variant (§4)                                                              | cw v1 error_catalog に 12 Code として 1:1 mapping する予定 (Phase 16 entry + task 4.26 系の error system migration 後)   |

### cw v1 stances on §6 open questions (recommended answers)

zwasm v2 spec §6 で 6 個の open question が cw v1 (consumer)
review を待っている。 cw v1 推奨回答:

| Q  | 質問                       | cw v1 推奨                                       | 理由                                                                                    |
|----|----------------------------|--------------------------------------------------|-----------------------------------------------------------------------------------------|
| Q1 | multi-result shape         | named struct を default、 anonymous tuple も継続 | Clojure `(let [{:keys [quot rem]} ...])` 形に自然変換、 anonymous は順序依存で相性悪い  |
| Q2 | Caller first arg           | optional (default 受けない、 必要時のみ宣言)     | pure fn の boilerplate 削減                                                             |
| Q3 | `mem.slice()` invalidation | snapshot (Wasm spec 準拠)                        | growth-tracking は per-access コスト永続化、 snapshot は境界明示で再取得すれば良い      |
| Q4 | WasiConfig granularity     | bulk 一括 default、 per-syscall は将来 opt-in    | cw v1 は wasi を環境としてまとめて利用                                                  |
| Q5 | TypedFunc cache lifetime   | stable across instance lifetime                  | `defineFunc` は `instantiate()` 前限定にすれば cache 安定、 動的追加は別 API へ分離が筋 |
| Q6 | ref-typed args             | typed wrappers (`FuncRef` / `ExternRef`)         | Zig 型システムの恩恵、 内部表現は `?u64` (0 sentinel) の薄い wrapper                    |

これらは cw v1 側の preference 表明であり、 zwasm v2 設計者の
最終判断を縛らない。 cw v1 は zwasm v2 の最終判断に追従する。

### What zwasm v2 needs from cw v1 going forward

cw v1 の今後の改修方向で zwasm v2 が知っておくべき事実:

- cw v1 NaN-box は Phase 5 entry で第二世代 (4×16=64 slot,
  44-bit shifted pointer, alignment shift 3) に拡張する。
  zwasm v2 の `*const FuncEntity` が `align(8)` 保証なら、
  cw v1 は Group D inline `funcref` slot をそのまま使う。
- cw v1 Phase 16 entry が cw v1 ↔ zwasm v2 直接結合の本番。
  それまでは zwasm v2 spec を foresight として保持。
- zwasm v2 rewrite (post-ADR-0109、 6-8 cycle 見積) と cw v1
  Phase 16 entry の timing sync は user 判断。

### Open requests to zwasm v2 (debt D-038 で追跡)

cw v1 から zwasm v2 への確認・依頼を debt D-038 に集約。 user
経由で zwasm v2 側に伝達するタイミングは別 (debt の Status が
"awaiting zwasm v2 reply" になる)。

**Cross-references**: F-001 (zwasm v2 unavoidable) + F-004
(NaN-box 64 slot) + F-006 (heap separation + allocator inject);
debt D-036 (Phase 16 zwasm integration shape) + D-037 (rewrite
timing) + D-038 (spec confirmation requests bundle) + D-039
(cw v1 io_interface vs WASI 責務分離);
`private/notes/zwasm_v2_feedback.md` (full draft note);
`.dev/structure_plan.md` `src/runtime/wasm/` subtree (Phase 16
file layout incl. marshal.zig / trap_map.zig / host_func.zig).

## F-009 — Feature-implementation neutrality: impl bodies live in namespace-neutral locations; Clojure / Java / cljw surfaces are thin wrappers above

**Status**: `confirmed` — direction of travel is law. Amendable only
by user direction + Revision history entry.

**Declared**: 2026-05-24 (user-directed structural session, landed
alongside ADR-0029).

### Rule

Feature-implementation bodies — i.e. the file that calls OS /
Zig-std or holds cw-original compute logic — live in
**namespace-neutral locations** under `src/runtime/`:

- Flat: `runtime/uuid.zig`, `runtime/clock.zig`,
  `runtime/file_io.zig`, `runtime/uri_parse.zig`, `runtime/path.zig`,
  `runtime/charset.zig`, `runtime/random.zig`, `runtime/print.zig`.
- Sub-directories (when one feature spans multiple files):
  `runtime/regex/{compile, match}.zig`,
  `runtime/crypto/{secure_random, message_digest}.zig`,
  `runtime/time/{instant, local_date, …}.zig`,
  `runtime/io/{interface, default}.zig`,
  `runtime/error/{info, catalog, print}.zig`,
  `runtime/wasm/{engine, linker, …}.zig`.

Three categories of surface — Clojure-ns, Java-ns, cljw-ns — all
connect **as thin wrappers from above**:

| Surface category | Location                                                             | Wrapper role                             |
|------------------|----------------------------------------------------------------------|------------------------------------------|
| Clojure-ns       | `src/lang/primitive/<feature>.zig` / `src/lang/clj/clojure/<…>.clj` | Var registration into `rt/` / clojure ns |
| Java-ns          | `src/runtime/java/<pkg>/<Class>.zig`                                 | Java FQCN 1:1 thin wrapper               |
| cljw-ns          | `src/runtime/cljw/<area>/<Item>.zig`                                 | cw-original symmetric thin wrapper       |

**Cross-surface calls are forbidden.** A Clojure-ns wrapper must not
import a Java-ns wrapper, and vice versa. Both reach the shared
neutral impl directly.

### Why

- The cw-v0 pattern (impl directly inside `src/lang/interop/classes/
  uuid.zig`) prevented sharing the same generator between
  `(random-uuid)` and `(java.util.UUID/randomUUID)`. Cross-namespace
  sharing requires a neutral implementation home.
- The zwasm-v2 Java-InterOp premise — *"for what is supported, no
  error surfaces; the internal implementation need not mirror Java;
  equivalent inputs and outputs (with side effects where applicable)
  are achieved via Zig-idiomatic means"* — explicitly authorises a
  Java surface to use cw-native data shapes internally, which in
  turn authorises implementation sharing.
- File fan-out across zones (one feature = impl + surface + ns
  registration ≥ 3 files) is structurally unavoidable. Mitigation
  comes from discoverability (feature-name consistency + index
  integrity in `compat_tiers.yaml` + grep-100% guarantee via
  guardrail G3), not from collapsing files together.
- At Phase 12+ the AI loop is statistically very likely to propose
  "inline impl into the surface for fewer files." F-009 lets the
  Devil's-advocate subagent (CLAUDE.md § Smell triggers are
  interrupts, not stops) automatically reject these envelope-
  violating alternatives.

### Out of scope

- Language-core foundations — `runtime/value/`, `runtime/collection/`,
  `runtime/numeric/`, `runtime/gc/`, `runtime/env.zig`,
  `runtime/dispatch.zig`, `runtime/keyword.zig`,
  `runtime/type_descriptor.zig`, `runtime/protocol.zig` — are
  outside this invariant. They *are* the representation of cw
  values; this invariant addresses OS-borrowed features (UUID,
  file I/O, regex, time, crypto hashes, …) and cw-original
  backends (zwasm engine, JIT codegen).

### Guardrails

- **G1** `scripts/zone_check.sh` extension — enforces D2 of
  ADR-0029 (no non-surface file in `runtime/` imports from
  `runtime/java/**` or `runtime/cljw/**`).
- **G2** `scripts/check_surface_marker.sh` — enforces the Backend
  marker docstring contract on every `runtime/java/**/*.zig` and
  `runtime/cljw/**/*.zig`.
- **G3** `scripts/check_feature_keyword.sh` — enforces 100% grep
  hit on the `keyword:` field across all files listed under each
  `compat_tiers.yaml` `host_classes` entry.

### Cross-references

- **ADR-0029** (this F-NNN's structural home).
- **Supersedes via ADR-0029**: ADR-0011 (the previous
  `runtime/host/<pkg>/` reservation pattern).
- **Related**: ADR-0007 (TypeDescriptor / Option β; thin wrappers
  register TypeDescriptors), ADR-0015 (io_interface Tier 1 / Tier 2
  shape; the `runtime/io/` consolidation is a continuation of this),
  ADR-0018 (error catalog SSOT; the `runtime/error/` consolidation
  groups its files together).
- **Schema home**: `compat_tiers.yaml` `host_classes` entries
  (extended schema per ADR-0029 D5 carries the `keyword:` and
  `files:` fields that G3 verifies).
- **Frequency basis**:
  `private/clojure_frequent_java_interop/00a_frequency_overview.md`
  (Java-package + class frequency data used to size the Phase 6+
  landing order).

### Revision history

- 2026-05-24 added: invariant landed alongside ADR-0029. Locks in
  the "implementation lives in a namespace-neutral place; all three
  surface families wrap it from above" shape. Sets up the
  Devil's-advocate subagent to reject Phase-12+ smallest-diff bias
  alternatives that would inline impl into a surface file.

---

## F-010 — Interim provisional goal = (Phase 15 完遂 + cw-v0-level JIT), then a quality-elevation loop prioritised over widening wasm FFI

**Status**: `confirmed` — direction of travel is law. Amendable only
by user direction + Revision history entry.

**Declared**: 2026-05-29 (user chat, interim-goal re-cut session).
**Verbatim**: 「あ、 ちょっとしっかりと「一旦の暫定ゴール」を切りなおし
たいです。 つまり、 Phase 15 完遂 + cw v0 程度の JIT までは組み込み。
wasm ffi は、 zwasm v2 やそれ以外のものを広げるより、 そこまで達したら、
cw v0 程度のカバー率、 fuzzing, clojuredocs のコードを clone してきて、
投稿されたコードをひたすら動かしてエラーがあれば根本的対処 (ついでに
読みやすい walkthrough ドキュメントを作り上げる、 ここまでは動作する
んですよ、 ということがコード主体でわかるドキュメント、 分量はどんどん
増えていってよい)、 リアルワールドライブラリをひたすらロードして動作
させてみる、 などを繰り返し品質を上げていくのを繰り返す。 ただし、 もち
ろん直すがあまりコードベース設計がどんどん workaround だらけや設計破壊、
汚いコードベースにならないように、 リファクタもしっかり挟む。 という想定
をしています」

**Decision answers captured same session**: (1) F-001 relationship =
**F-010 new + re-sequence** (F-001's "eventual unavoidability" stays
true and is NOT superseded; this entry schedules it AFTER the quality
loop). (2) walkthrough doc home = **`docs/works/`, explicitly outside
F-007** (a living capability ledger, distinct from the dormant
`docs/ja/learn_clojurewasm/` narrative chapters — user opts into this
new doc kind here).

### The interim milestone (M)

**M = Phase 15 完遂 + a cw-v0-程度 JIT landed.**

- **Phase 15 完遂** = the 7 concurrency buckets: atom+watch, STM
  transaction engine (doGet/doSet/commit-retry + commute + barge),
  agent+pools, future/promise/delay multi-thread swap, locking +
  volatile, pmap + deref-timeout, concurrent test layer + flag flip.
- **cw-v0-程度 JIT** = a narrow ARM64 integer-loop JIT matching cw v0's
  `jit.zig` scope (~700–1000 LOC, counter trigger, leaf C-ABI fn,
  deopt-on-non-int). Prerequisite chain: superinstruction/fusion pass →
  JIT go/no-go → narrow JIT. NOT a broad/optimising JIT.

Reaching M does **not** require finishing the quality loop; M is the
entry gate INTO the quality loop.

### After M — the quality-elevation loop (the standing work mode)

Once M is reached, the loop's standing task is **quality consolidation
through real Clojure code**, in preference to widening wasm FFI breadth:

1. **Coverage** toward cw-v0 parity-PLUS (cw v1's native deftype gives
   a higher ceiling than cw v0's Tier-D class drop).
2. **clojuredocs differential** — run posted `:examples` through cljw
   (and JVM Clojure where feasible), root-cause every divergence.
3. **Real-world library loading** — `clojure-corpus` libraries through
   cljw, exercise their suites, root-cause failures.
4. **Fuzzing** — differential vs JVM Clojure + generative properties.
5. **`docs/works/` walkthrough docs** — code-主体 "this works" ledger,
   volume grows freely.

### The non-negotiable discipline (the user's "ただし")

**Fixes must not rot the codebase.** Every fix is held to F-002
(finished-form wins): a fix that would require a workaround / design
break triggers a depth-2+ surgery instead, and a **refactor gate**
runs periodically (built-in `simplify` + smell audit) so the bug-fix
stream does not accrete into a dirty codebase. "直すが workaround
だらけ・設計破壊・汚いコードベース" is the explicit failure mode this
invariant forbids.

### What this changes for the loop

1. **wasm FFI breadth is de-prioritised, NOT cancelled.** F-001 stays
   law (zwasm v2 integration is eventually unavoidable); F-010 schedules
   it AFTER the quality loop. The loop must not widen wasm FFI surface
   (zwasm v2 or other wasm targets) before M + a quality-loop pass,
   unless the user re-directs.
2. The ROADMAP Phase 16+ is re-aimed: JIT chain moves earlier (into the
   M window); the quality loop becomes the post-M standing phases; zwasm
   v2 slides right. Exact numbering in the strategy ADR + §9 re-wiring.
3. The quality loop is **repeatable**, not a one-shot phase — each pass
   carries a refactor gate.
4. v0.1.0 (Phase 14) still completes first — M is sequenced after it.

**Cross-references**: F-001 (wasm FFI unavoidable — re-sequenced, not
superseded) · F-002 (finished-form discipline the refactor gate
enforces) · F-007 (chapter cadence dormant — `docs/works/` is a
distinct, opted-in doc kind) · the strategy ADR + ROADMAP §9 re-wiring
landed alongside this entry · `.dev/reference_clones.md` Quality-
elevation corpora (`clojure-corpus` + `clojuredocs-export-edn`) ·
planning note `private/notes/recut-goal-synthesis.md` + the 3 surveys
it digests.

### Revision history

- 2026-05-29 added: interim-goal re-cut. Milestone M = Phase 15 +
  cw-v0-level JIT; post-M quality-elevation loop prioritised over wasm
  FFI breadth; refactor-gate discipline mandatory. F-001 re-sequenced
  (not superseded) per user decision; `docs/works/` opted in outside
  F-007 per user decision.

---

## F-011 — Commonization + clean code + behavioural equivalence are prioritised over effort cost; verify equivalence against real Clojure (`clj`)

**Status**: `confirmed` — direction of travel is law. Amendable only
by user direction + Revision history entry.

**Declared**: 2026-05-31 (user chat, during the structural-defect
hunting session).

**Verbatim**:
1. 「いくら労力がかかっても、 共通化やきれいなコード、 動作等価
   （内部動作や表現とかは色々変わってもいいが）を優先してね」
2. （最適化観点について）「コメントやad-hoc感がないように共通機構が
   あるとうれしいが、 難しければまあ局所最適化でもいいか。 cw v0の状況
   なんかも参考程度にはしてください（ただし完コピというよりも、 この
   プロジェクトにふさわしい形で取り込むか、 発想のタネにする）」
3. （差分オラクルについて）「入力 => 出力 であれば、 本家 clj を実際に
   実行させてみることで差分（もちろん異常系も、 ただし、 フォーマットは
   違うかもしれんが）を検知することもできます」+「それらも新セッション
   でもワークするように、 配線しておいてね」

**What this changes for the loop**:

1. **Commonization (DRY / shared mechanism) outranks effort.** When a
   fix can land either as a per-site ad-hoc patch OR as a single shared
   mechanism, the **shared mechanism wins regardless of how much more
   work it is**. "ad-hoc 感 / コメントで言い訳する" local fixes are the
   failure mode this forbids. This strengthens F-002: not only does the
   finished form win, but the *commonised* finished form wins over the
   duplicated one. Example landed this session: record associative read
   unified into `lookup.recordGet` (one Layer-0 source for both `(:k
   rec)` and `(get rec k)`) rather than two copies.
2. **Behavioural equivalence is the correctness target; internals are
   free.** Observable input→output (including error CASES) must match
   real Clojure. Internal mechanics + representation may diverge freely
   (NaN-box layout, GC, no-JVM-Class, the `.type_descriptor` / synthetic
   exception-class-name bridge, etc.). This is F-005's "JVM surface
   compat, Zig-native internal" generalised to *all* observable
   behaviour, not just the numeric tower. Where cljw deliberately
   diverges on a SURFACE detail (e.g. `(class 5)` prints `Long` not
   `java.lang.Long` per the no-JVM rule), that divergence is a recorded
   ADR decision, not an accident.
3. **The clj differential oracle is a first-class tool, wired durably.**
   `clj` (`/opt/homebrew/bin/clj`, Clojure CLI) is the ground-truth
   oracle for input→output equivalence, **including error cases** (the
   error MESSAGE FORMAT differs — cljw vs `Execution error
   (<Class>)…` — but the exception CLASS and the VALUE must match).
   The loop runs `clj -M -e '<expr>'` to derive the expected output
   when probing, rather than guessing. See
   `.dev/reference_clones.md` (oracle entry) +
   `.dev/lessons/structural_defect_hunting.md` (oracle in the probe
   sweep) — both wired so a fresh session picks the oracle up.
4. **Optimization prefers a shared mechanism; cw v0 is an
   inspiration-seed, not a copy.** Perf work (D-163 interpreter
   per-element overhead, future JIT/fusion) should land as a common
   mechanism (superinstruction/fusion, a reduce-over-range fast-path)
   rather than ad-hoc per-call-site hacks. Local optimization is the
   fallback only when a shared mechanism is genuinely infeasible. cw v0
   (`~/Documents/MyProducts/ClojureWasm`) is consulted as a
   precedent/seed and re-derived in a cljw-appropriate shape, never
   copied verbatim (per `no_copy_from_v1.md`).
5. **Effort / cycle / diff size is NOT a reason to pick the ad-hoc
   path.** This closes the same loophole F-002 + the Cycle-budget-defer
   smell close, from the commonization angle: "the shared mechanism is
   more work" is never a sufficient reason to ship the duplicated /
   local form.

**Cross-references**: F-002 (finished-form wins — F-011 adds the
commonization + behavioural-equivalence axes) · F-005 (numeric-tower
surface compat — the behavioural-equivalence precedent F-011
generalises) · F-009 (feature neutrality — shared impl home) ·
`no_copy_from_v1.md` (v0 as seed not copy) · `no_jvm_specific_assumption.md`
(internals diverge) · D-163 (perf: shared mechanism over ad-hoc) ·
`.dev/reference_clones.md` + `.dev/lessons/structural_defect_hunting.md`
(clj oracle wiring) · `private/notes/phaseA26-clj-differential-oracle.md`
(the running oracle log).

### Revision history

- 2026-05-31 added: commonization + clean-code + behavioural-equivalence
  prioritised over effort; clj differential oracle wired as a first-class
  tool; optimization prefers shared mechanism with cw v0 as seed.

---

## F-012 — Production default backend is the VM; tree_walk is the differential oracle

**Status**: `confirmed` — direction of travel is law. Amendable only by user
direction + Revision history entry.

**Declared**: 2026-06-02 (user chat, during the backend-default drift audit).

**Verbatim**:
1. 「デフォルトtreewalkがまずくないかなあ？treewalkはいずれにしても実装する線上に
   のってて、しかも本番配布時にはデフォルトvm（高速）であるべきだと思うんですが」
2. 「わたしの記憶だと、デフォルトをvmに設定しろと伝えた記憶があるが、本当はどうだ？」
3. 「どこかで方針変えたのかな」

**What this changes for the loop**:

1. **The production / distribution default backend is the VM** (the fast path).
   `tree_walk` is retained as the **differential oracle + reference
   implementation** (evaluator.compare, diff_test, the corpus gate), never as
   the shipped default. This matches ROADMAP §349 ("default is VM after Phase
   4") — the original plan; tree_walk-default was only the "until 4.12 confirms
   parity" interim (4.8), and 4.12 confirmed parity.
2. **The 2026-06-02 audit found the flip was never executed** (drift): build.zig
   kept `orelse .tree_walk` and ADR-0050/0056/0036 narrated tree_walk-default as
   intended. A flip experiment proved the VM is not yet production-ready (5 e2e
   failed on VM-default) — i.e. tree_walk-default was **masking real VM gaps**.
3. **The flip is now an explicit, gated target** (ADR-0070 + D-196): the default
   stays tree_walk ONLY until the enumerated VM-parity blockers are closed and
   the full gate is green under `-Dbackend=vm`; then build.zig flips to `vm`.
   Any future default change is a user-owned F-NNN amendment, never a quiet edit.
4. **VM parity is gated, not assumed**: a VM-parity probe runs e2e + corpus on
   the VM build; on D-196 close it becomes a hard per-commit gate so VM
   divergences can never be silently masked again.

**Cross-references**: ROADMAP §349 + build.zig 4.8 comment (original VM-default
intent); ADR-0070 (intent + blocker list + flip gating); D-196 (the parity
blocker cluster); ADR-0005 (dual-backend oracle); ADR-0050/0056/0036 (the drift
narration this corrects); F-002 (finished-form: production ships the fast path);
F-010 (VM is the JIT/perf substrate); F-011 (tree_walk oracle verifies
behavioural equivalence).

### Revision history

- 2026-06-02 added: user re-asserted the §349 VM-default intent during the
  drift audit; recorded VM-as-production-default as law, the flip gated on
  D-196 parity blockers (the flip experiment surfaced 5 masked VM gaps).

---

## F-013 — Library-driven discovery surfaces gaps; the response is definition-derived comprehensive coverage in canonical (Zig-equivalent, non-JVM) form, never an ad-hoc "just make this lib pass"

**Status**: `confirmed` — direction of travel is law. Amendable only by user
direction + Revision history entry.

**Declared**: 2026-06-07 (user chat, during the D-275 deftype/reify `Object`
slice — the question "個別最適化に落ちる入口を構造的に防げないか").

**Verbatim** (user, 2026-06-07):

1. 「ライブラリ駆動は未実装をあぶり出す手法であるけれども（…なんらかの漏れは
   しかたない）、しかし、その場合ただ「通すだけ」のad-hocを避け、…「登場しうる
   ことを網羅」「正統な形で（つまり、JVM再実装ではなくて、Zig等価、このプロジェ
   クトの形を守る）」という形で定式化から導出される対応で一段階システムが向上、
   その結果ライブラリが実行できるようになる、としたほうが、潜在的に他のライブラ
   リも対応範囲が増えていて、だんだんライブラリロードのエラーがおきにくくなり
   そう」
2. 「java.xxx.の大玉がありますが、ディレクトリ分離などにより明示化（…Java再実装
   ではなくて、どうせ必要になるものをZigで用意している、正統な用意）しているので、
   手間がかかっても良いこと」

**What this changes for the loop**:

1. **Real-library loading is a *discovery technique*, not a feature list.**
   `require`-ing actual Clojure libraries (the convergence campaign's ladder,
   F-010 `docs/works/`) is how the loop finds the gaps left by fast AI-driven
   construction. A failed load is a *signal*, not a task to silently satisfy.
2. **The response to a discovered gap is forbidden to be ad-hoc "make this lib
   pass."** When a load fails on a missing capability, the fix must:
   - **網羅 (cover the whole class that can appear)** — derive the full set of
     things that *can* legitimately appear from the **definition** (the Clojure
     language spec / the host-interface surface / the numeric tower / …), not
     from "what this one library happened to use."
   - **be canonical (定式化から導出)** — implement in cljw's own shape:
     Zig-equivalent behaviour (F-011), namespace-neutral impl with thin surfaces
     (F-009), no JVM reimplementation (ADR-0059). A Java/`clojure.lang` surface
     prepares "what will be needed anyway" in Zig — a legitimate, deliberate
     preparation, not a per-library shim.
   - **raise the system one level** — a definition-derived fix monotonically
     improves coverage for *other* libraries too, so library-load errors trend
     downward over time. An ad-hoc fix improves exactly one library and leaves
     the next one to re-discover the same gap.
3. **The "個別最適化 entry" must be closed structurally, not by vigilance.**
   Where a capability set is hand-maintained (an allowlist of recognised names,
   a per-case `if`), it tends to grow library-by-library — the failure mode this
   F-NNN forbids. The structural defenses: a single closed-set SSOT whose keys
   come from the *definition* (not from libraries seen), + a mechanical gate that
   (a) bounds the recognised set to the definition-derived closed set and (b)
   requires every recognised entry to route to a *generic* surface (so a
   per-library shim has no slot). `compat_tiers.yaml` (Java classes, A/B/C/D) is
   the prior art; ADR-0102 applies the same pattern to the deftype/reify
   host-interface surface (`host_interfaces.yaml`).
4. **The acceptable bound on comprehensiveness is single-binary cost.** 網羅
   tempts "model/load everything up-front", which grows binary size + cold-start
   (a dimension under-considered in the original plan; single-binary is the
   shipped form, dynamic loading / split binaries are both currently undesirable).
   The reconciliation: 網羅 the *recognition/closed-set table* (cheap — rows, no
   impl) up-front; **wire impl incrementally** (each wire generic + gated). The
   tension (eager comprehensiveness vs binary/startup budget) is tracked as a
   standing concern (debt row D-277), revisited if the mission cold-start / size
   target is threatened — not solved pre-emptively.

**Cross-references**: F-009 (impl neutrality — the shared-impl home that makes a
definition-derived fix reusable across surfaces) · F-011 (behavioural
equivalence vs `clj` — the "canonical / Zig-equivalent" half) · F-002
(finished-form wins — the structural close beats the smallest-diff per-lib
shim) · ADR-0059 / AD-003 (no-JVM — "non-JVM reimplementation") ·
`.claude/rules/clj_diff_sweep.md` Discipline 2 (big-bang, don't drip-feed — the
sweep-domain instance of the same principle) · ADR-0102 (the host-interface SSOT
+ gate — the first mechanical instance of clause 3) · D-277 (the binary/startup
concern of clause 4) · principle.md "Ad-hoc-pass smell".

### Revision history

- 2026-06-07 added: user declared the discovery-vs-response philosophy during
  the D-275 `Object` slice and asked for the 個別最適化 entry to be closed
  structurally. Recorded as law; the first mechanical instance is ADR-0102
  (host-interface closed-set SSOT + gate).
