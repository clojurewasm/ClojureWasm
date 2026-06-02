# cw v0 parity snapshot + gap-incorporation plan

> **Purpose** (user directive, 2026-05-29): persist the cw-v0-vs-cw-v1
> coverage/parity analysis as a reference, and prepare — with **ROADMAP
> amendment in scope** — how the loop will incorporate the missing
> pieces. The user's framing (verbatim):
>
> > 「次から確実にその不足部分のうち、cw v1に盛り込むべきもの(大半が
> > そうだが、そのまま真似しろというわけではない、cw v1のつくりの上で、
> > より良い設計・順序で)しっかり先程のレポート表示はどこかに書き出して
> > 参考資料とした上で、どう取り組むかをロードマップ改変も視野に入れて
> > 取り組ませる準備をしておいてください。」
>
> So: **most v0 gaps SHOULD be incorporated, but NOT copied as-is** —
> redesigned on cw v1's architecture with better design + ordering.
>
> ## How the loop uses this doc (F-003 discipline)
>
> This is **foresight, not decision**. Per F-003 + `.dev/principle.md`
> Structural-imagination phase: the per-gap "cw-v1 redesign direction"
> + "ordering" below are the **owning phase's design input**, not a
> seized decision. When a gap's owning phase/row opens, the owner reads
> this doc, then decides the concrete shape (Devil's-advocate per
> CLAUDE.md if depth ≥ 2) and **amends the ROADMAP §9 row in place per
> §17**, referencing this doc. Gaps with NO existing ROADMAP row
> (`deps`/`test`/`--list-vars`/some namespaces) are where amendment is
> most needed — they get NEW §9 rows minted at incorporation time.
>
> Read at cold-start (added to handover reading order). Amend this doc
> in place as gaps are incorporated (move a row to "Done" with the
> landing commit).

---

## 1. Parity snapshot — cw v1 vs cw v0 (2026-05-29)

**Headline**: cw v1 ≈ **60-70% of cw v0's surface in ~half the LOC**
(43K vs 87.5K). Numeric tower / GC / error-UX are equal-or-ahead; v0's
production-mature **JIT, rich nREPL/REPL, deps/test toolchain, Wasm
Component output** are **intentionally ordered later** (F-010). cw v1's
native deftype + dual-backend oracle give a structurally higher ceiling
(parity-PLUS). Position: Phases 1-13 DONE, Phase 14 (v0.1.0) IN-PROGRESS
(release HELD per user), Phases 15-20 PENDING.

> Honest caveat: v0's 651/706 clojure.core vars (Zig bootstrap) and cw
> v1's "158 .clj defs + 211 primitive leaves (overlap)" are not directly
> comparable. The % is a per-dimension estimate; var-exact parity is
> quantified later via the clojuredocs differential (F-010 quality loop).

### 1a. Core language

| Dimension                 | cw v0                                          | cw v1                                        | Status                                         |
|---------------------------|------------------------------------------------|----------------------------------------------|------------------------------------------------|
| Zig LOC                   | 87.5K                                          | 41.5K                                        | half, in progress                              |
| clojure.core vars         | 651/706 (92%)                                  | ~158 .clj + 211 primitive                    | 🟡 D-134 backlog                                |
| special forms             | full + JVM-compat                              | 16 (incl. `binding`)                         | 🟡                                              |
| namespaces                | ~30                                            | 12                                           | 🟡 spec/math/io/repl/reducers absent            |
| host classes / interop    | 7 native + `.`/`new`                           | 43 reserved + `.`                            | 🟡 time/net/crypto backing absent (D-105/D-106) |
| backends                  | Register-IR VM + JIT                           | tree_walk (prod) + VM (partial)              | ⭐ dual-backend differential oracle             |
| GC                        | MarkSweep                                      | MarkSweep + arena + free-pool + root-set     | ✅ equal (no generational either side)         |
| numeric tower             | BigInt/Ratio/BigDecimal                        | auto-promote + universal `=`/`compare`       | ✅ equal                                       |
| lazy-seq                  | full chunked                                   | Layer-2 (map/filter/range/iterate)           | 🟡 infinite range etc. (D-134(b))               |
| metadata (with-meta/meta) | yes                                            | none                                         | ❌ D-075                                       |
| STM/concurrency           | atom/future/promise/agent/pmap (no ref/dosync) | atom/future/promise/delay + STM Ref skeleton | 🟡 Phase 15                                     |
| macros                    | full + user defmacro                           | user defmacro                                | 🟡 `&form`/`&env` D-111                         |
| Wasm FFI                  | 523 opcodes / Wasm 3.0 / WIT                   | none                                         | ❌ F-001, F-010-deferred                       |

### 1b. CLI

| Feature                                      | cw v0                        | cw v1                                | Status                              |
|----------------------------------------------|------------------------------|--------------------------------------|-------------------------------------|
| `-e` / file / `-` stdin                      | ✅                           | ✅                                   | ✅                                  |
| `repl`                                       | ✅ line_editor (1196 LOC)    | 🟡 line-buffered (D-116)              | 🟡                                   |
| `nrepl --port`                               | ✅ 15 ops (history)/now stub | 🟡 4 ops                              | 🟡                                   |
| `build` (self-contained bin)                 | ✅                           | ✅ + embedded-trailer self-run       | ✅                                  |
| `render-error` (post-mortem)                 | ❌                           | ⭐ `CLJW_ERROR_LOG` EDN replay        | ⭐                                   |
| `--compare` (dual-backend diff)              | ❌                           | ⭐ TreeWalk vs VM, exit 1 on mismatch | ⭐                                   |
| `component build` (Wasm CM)                  | ❌                           | ❌ (14.12 `[ ]`, zwasm-v2 gate)      | differentiation core, both unbuilt  |
| `test` / `deps` / `-m` / `new` / `--version` | ✅ (Clojure CLI toolchain)   | ❌                                   | ❌ v0 utility, no cw-v1 ROADMAP row |

### 1c. nREPL richness (v0 full = git `da201d9~1`, 1818 LOC / 15 ops)

| op                                  | cw v0 | cw v1       | CIDER need   |
|-------------------------------------|-------|-------------|--------------|
| clone / close / describe / eval     | ✅    | ✅          | required     |
| stdout/stderr capture               | ✅    | ❌ (D-118)  | **required** |
| complete / info / eldoc / lookup    | ✅    | ❌ (D-117c) | high         |
| ls-sessions / multi-session         | ✅    | ❌ single   | high         |
| load-file / macroexpand / interrupt | ✅    | ❌ (D-117)  | mid          |

Verdict: v0 = CIDER-class; cw v1 = handshake-only (connects, but
`(println …)` output never reaches the client). bencode codec done; the
gap is ops + per-session `*out*`/`*err*` dynamic binding + thread-per-session.

### 1d. Planned-UX scorecard

- **Error UX (P6)** → ⭐ cw v1 *exceeds* v0 + the plan: carat-pointer +
  EDN + `render-error` + `CLJW_ERROR_FORMAT`/`LOG` + `with-context`,
  error_catalog SSOT. **cw v1's strongest area.**
- **REPL line-editing** → 🟡 v0 full (history/completion/multi-line);
  cw v1 line-buffered (D-116).
- **Learning docs** → JA chapters permanently dormant (ADR-0025/F-007);
  `docs/works/` capability ledger planned (F-010), grows post-M.
- **`--list-vars` / tier introspection** → SSOTs (compat_tiers/placement)
  ready; command unbuilt (both sides).
- **AOT self-contained binary** → ✅ both (cw v1 = ADR-0034).
- **Wasm Component output** → ❌ the differentiation core; v0 none, cw v1
  14.12 deferred (zwasm-v2 gate).

### 1e. JIT

v0 = `src/engine/vm/jit.zig` 721 LOC ARM64 PoC (hot integer loop,
`JIT_THRESHOLD=64`, leaf C-ABI, deopt) — but `fib_recursive` 1.0x
(never reaches a hot loop in real code). cw v1 = none. Original plan =
Phase 17 broad JIT; F-010 re-cut = M = "cw-v0-程度 JIT" (narrow ARM64
integer-loop, ~700-1000 LOC). D-133 = the coverage-floor ordering owner.
F-001 = zwasm v2 has its own JIT (Phase 16, territorial overlap unsolved).

---

## 2. Gap-incorporation plan

For each gap: **incorporate?** + **cw-v1 redesign direction** (NOT a
v0 copy — the better shape on cw v1's architecture) + **ordering** +
**ROADMAP-amendment hook** + **debt row**. Direction is foresight; the
owning phase decides the concrete design (F-003).

| #   | Gap                                                                  | Incorporate                    | cw-v1 redesign direction (not v0 copy)                                                                                                                                                                                                                                                                                                     | Ordering                               | ROADMAP hook                                                                                | Debt              |
|-----|----------------------------------------------------------------------|--------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------|---------------------------------------------------------------------------------------------|-------------------|
| G1  | nREPL richness (ops + out/err + multi-session)                       | **Yes (CIDER-class)**          | Build per-session `*out*`/`*err*` on the **just-landed dynamic-var infra** (`binding` + `*error-context*` pattern); thread-per-session via Phase-15 concurrency; `complete`/`info`/`eldoc` over the **compat_tiers/placement SSOT** (shared with `--list-vars` G11) — not v0's ad-hoc op handlers                                         | **Phase 15** (concurrency unblocks it) | Amend §9.17 (Phase 15) — add nREPL-richness rows, OR a dedicated post-15 row              | D-117, D-118      |
| G2  | REPL line-editor                                                     | **Yes**                        | `src/app/line_editor.zig`: TTY raw-mode, history-persist, completion via the SSOT (G11). v0's 1196-LOC editor is the spec; cw v1 trims to the ergonomic core first                                                                                                                                                                         | Post-M quality loop / opportunistic    | New §9 row in the quality-loop phase                                                       | D-116             |
| G3  | JIT (narrow ARM64)                                                   | **Yes (M gate)**               | **Order-first redesign**: superinstruction/fusion pass → coverage-floor green (interop `.`/`new` D-130, lazy-seq, D-134 core) → THEN the narrow JIT — so cw v1 avoids v0's `fib 1.0x` trap (hot loop reachable in real code). NOT v0's 721-LOC PoC verbatim                                                                             | **Post-Phase-15, M window**            | Re-aim Phase 17 earlier per F-010; amend §9 JIT rows; resolve zwasm-v2 JIT overlap (F-001) | D-133             |
| G4  | metadata system (with-meta/meta + reader `^{}` + IObj/IMeta)         | **Yes**                        | **Split the surface**: (a) narrow `^:keyword` reader-metadata for `def` flags (`^:dynamic`/`^:private`/`^:macro`) — Form-time, NOT runtime value-metadata, unblocks user dynamic vars cheaply; (b) full runtime value-metadata (HeapHeader slot + IObj/IMeta) — needs the F-004 NaN-box meta-slot decision. (a) can land well before (b) | (a) opportunistic; (b) focused cycle   | (a) new §9 row; (b) **may need an F-004 amendment (user-owned)** for the slot              | D-075             |
| G5  | host backing impls (time / net / crypto)                             | **Yes**                        | TypeDescriptor reservations exist; land neutral `runtime/time/` + `runtime/net/` + `runtime/crypto/` impls per **F-009** (impl-neutral, shared across Java/cljw/Clojure surfaces)                                                                                                                                                          | Quality loop / opportunistic           | Focused §9 rows (host-stdlib waves)                                                        | D-105, D-106      |
| G6  | `deps` / `test` / `-m` / `new` toolchain                             | **Selective**                  | `cljw test` (run `test/clj/` conformance) = high value, build on existing test layer. `deps` (deps.edn git/maven) = big; scope-cut or defer (cw v1 may favor a leaner module story, `modules/` already exists). `-m`/`new` = conveniences. **NOT a v0 `deps.zig` port**                                                                    | Quality loop                           | **NEW §9 rows (no current rows)** — primary ROADMAP-amendment site                        | file new D-NNN    |
| G7  | namespaces (math / spec.alpha / java.io / reducers / instant / repl) | **Selective**                  | `clojure.math` (Pattern-A, cheap) first; `clojure.spec.alpha` (large — survey `spec.alpha/` + `malli/` per textbook_survey, cw-v1-idiomatic); `clojure.java.io` over `runtime/io/`. Add by real-corpus demand (F-010 quality loop), not bulk                                                                                              | Quality loop (demand-driven)           | New §9 rows per namespace                                                                  | file per-ns D-NNN |
| G8  | Wasm Component output (`cljw component build`)                       | **Yes (differentiation core)** | F-001/zwasm v2 integration per F-008 spec; **F-010 orders it AFTER the quality loop** (Phase 16). Not v0 (v0 had none); the design is the zwasm-v2 consumer shape                                                                                                                                                                          | **Phase 16** (post-M, zwasm-v2 ready)  | §9.18 Phase 16 (already placeholder)                                                       | D-036/037/038     |
| G9  | clojure.core remaining (lazy (b) + breadth)                          | **Yes (recurring)**            | Cluster-by-cluster over existing primitives; lazy forms with the lazy-seq Layer-2 wiring                                                                                                                                                                                                                                                   | Recurring quality-loop                 | §9.16 row 14.13 follow-ups + quality-loop rows                                             | D-134             |
| G10 | multimethods breadth / `&form`/`&env`                                | **Yes**                        | `&form`/`&env` injection into the user-macro path (decide Value shapes for Form/Scope); multimethod breadth audit                                                                                                                                                                                                                          | Opportunistic / test-corpus-driven     | Follow-up rows                                                                              | D-111             |
| G11 | `--list-vars` / tier introspection                                   | **Yes**                        | `cljw --list-vars` reading `compat_tiers.yaml` + `placement.yaml` (SSOTs ready); shared completion source for G1 nREPL + G2 REPL                                                                                                                                                                                                           | Quality loop                           | New §9 row                                                                                 | file new D-NNN    |
| G12 | generational GC                                                      | **Defer**                      | Both sides future (ROADMAP §89.2); cw v0 reached maturity without it. Not a near-term gap                                                                                                                                                                                                                                                 | Far future                             | §89.2 reserve                                                                              | (none)            |

### Cross-cutting ordering note

The single highest-leverage observation: **G1 (nREPL out/err) + G4a
(reader `^:dynamic`) build directly on this session's dynamic-var work**
(`binding` + `*error-context*` + `Env.on_deinit_hook`). G3 (JIT) is
gated behind the coverage floor (G9 + interop). So a natural sequence
toward M: finish G9/D-134 lazy + interop coverage → Phase 15 (unblocks
G1) → superinstruction/fusion → G3 JIT → M → quality loop (G5/G7/G11 +
`docs/works/`) → G8 (zwasm v2). G4/G6/G2 slot into the quality loop as
demand surfaces.

---

## 3. Cross-references

- Source analysis: this session's 2 parity subagents (2026-05-29);
  cw v0 evidence in `~/Documents/MyProducts/ClojureWasm/`
  (`DIFFERENCES.md`, `README.md`, `src/engine/vm/jit.zig`,
  git `da201d9~1:src/app/repl/nrepl.zig`).
- F-010 (`.dev/project_facts.md`) — the interim-goal re-cut this plan
  serves; F-001/F-004/F-006/F-008/F-009 — the decreed constraints.
- `.dev/structure_plan.md` — sibling foresight doc (directory tree).
- `.dev/debt.yaml` — the per-gap tracking rows.
- ROADMAP §17 — the amendment policy each incorporation follows.
