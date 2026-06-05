# ADR-0099 — Minimal polyglot Wasm FFI surface (`wasm/load` + `wasm/call`) behind a `-Dwasm` build flag, embedding zwasm v2

- **Status**: Proposed → Accepted (2026-06-06)
- **Driven by**: the Clojure/conj 2026 CFP (D-256) **P1 — the heart of the
  talk**: a Clojure REPL loading a sandboxed Rust/Zig-compiled `.wasm` and
  calling it like a namespace ("WebAssembly as an FFI"). This is the one thing
  no other Clojure runtime demonstrates.
- **Pulls forward**: the planned `runtime/cljw/wasm/` surface
  (structure_plan.md §wasm, feature_name_consistency.md R3, Phase 16) as an
  **F-001 forward spike** — NOT the ADR-0006 Phase-16 full-FFI reintroduction.
- **Relates to**: F-001 (zwasm v2 unavoidable, lazy+flag-guarded), F-002
  (finished-form wins), F-004 (NaN-box Group D wasm slots), F-006 (GC
  dual-heap), F-009 (impl/surface split), ADR-0006, ADR-0098, D-037/D-038
  (the zwasm embedding spike), D-259 (the provisional handle close-out).

## Context

The CFP's differentiator is polyglot: WebAssembly as an FFI, so a Clojure REPL
can `(wasm/load "add.wasm")` a module compiled from another language and
`(wasm/call inst "add" 2 40)` → `42`. The Zig-level feasibility is already
proven: the D-037 spike (`spike/zwasm_embed.zig`, `zig build zwasm-spike`)
consumes zwasm v2's embedding API via a `build.zig.zon` relative-path import
and returns `42`. What is missing is the **Clojure-level surface**.

F-001 is the governing constraint. zwasm v2 is under active AI development on
its `zwasm-from-scratch` long-lived branch; the loop **must not** make cljw's
default build or `test/run_all.sh` gate depend on it (a churning zwasm tree
must never break cljw's gate). The spike satisfies this with a LAZY,
flag-guarded dep (`-Dzwasm-spike`). The full Phase-16 form (`runtime/wasm/`
with linker/host_func/wasi/funcref-slots/trap_map/pod_boundary,
structure_plan.md:191-203) is owned by the Phase-16 entry (D-036 inline-vs-Pod
is still open). This ADR is the **forward spike toward** that form, behind the
same isolation, not its closure.

zwasm v2 embedding ownership (read from `~/Documents/MyProducts/zwasm_from_scratch`
on the `zwasm-from-scratch` branch): `Engine` owns the c-api `*Store`;
`Module`/`Instance` hold pointer-value copies of `c_store` (not self-referential
into each other's storage), so an `Engine`+`Module`+`Instance` triple is
heap-boxable and movable — only deinit-order (instance→module→engine) and
"engine outlives instance" matter. The untyped dynamic path
`Instance.invoke(name, []const Value, []Value)` + `exportFuncSig(name) ?FuncType`
is the marshal driver (a comptime `typedFunc` is unusable — the wasm signature
is only known at runtime).

## Decision

**Implement a minimal `wasm/load` + `wasm/call` surface under
`runtime/cljw/wasm/`, embedding zwasm v2, activated only by a `-Dwasm` build
flag. The default build + gate set `wasm=false` → zero zwasm symbols, `wasm`
namespace absent (F-001 preserved).**

1. **Build flag (F-001 isolation)**: `-Dwasm` (default false). When set, and
   only when the lazy `zwasm` dep actually resolves, `build.zig` adds the
   `zwasm` import to the cljw `exe_mod` AND sets `build_options.wasm=true`.
   `build_options.wasm` is set `true` *only inside* the resolved-dep block, so
   the null-first-pass of `b.lazyDependency` leaves it false (no `@import("zwasm")`
   is then analysed → no compile error). Default `zig build` / `run_all.sh`
   never reach `b.lazyDependency` with the flag → no fetch, no symbols.
2. **Surface placement** (Alt-2, per the DA): three files under
   `runtime/cljw/wasm/`, drawn on the Phase-16 file boundaries so Phase-16 is
   *addition, not extraction*:
   - `engine.zig` — the zwasm Engine/Module/Instance lifecycle wrapper. Its
     public fn shapes (`load(alloc, bytes) -> *Loaded`, `Loaded.invoke`,
     `Loaded.exportSig`) match the Phase-16 module/instance split, so the later
     split does not change callers. **F-006 seam**: the allocator is a *named
     parameter* of `load`, never an inline global grab — the cw-GC-allocator
     inject point structure_plan.md:192 names is already here (P1 passes
     `rt.gpa`, the F-006 layer-1 backing allocator, NOT the moving GC heap).
   - `marshal.zig` — Clojure Value ↔ `zwasm.Value`, driven by `exportFuncSig`
     ValTypes (int→i32/i64, float→f64-bits via `@bitCast`, and back). The
     load-bearing finished-form piece.
   - `surface.zig` — `register(env)` + the `wasmLoadFn`/`wasmCallFn` builtins,
     thin, mirroring `cljw/http/server.zig`. Registers ns `wasm` with `load`,
     `call`.
   Plus `wasm_handle.zig` (the single provisional-handle wrap/unwrap site, §4).
   Wired by one line in `runtime/cljw/_host_api.zig` under
   `if (build_options.wasm)`.
3. **API (2-call, auto-sig)**: `(wasm/load "path.wasm")` → an opaque instance
   handle Value; `(wasm/call handle "export" & args)` → result (single result =
   scalar, multiple = vector). Arg/result types are **derived from
   `exportFuncSig`** — no hand-written `:params`/`:results` (the v0 shape). v0's
   `load`→module / `fn`→callable / call split is a DIVERGENCE data point, not
   copied (no_copy_from_v1.md); v2's runtime sig probe makes the 2-call shape
   sufficient.
4. **Provisional instance handle (D-259)**: the handle is a GC-allocated
   `WasmHandle { header: HeapHeader, loaded: *Loaded }` tagged with the
   **already-reserved** `HeapTag.wasm_module` (slot D4), wrap/unwrap isolated to
   `wasm_handle.zig`, `PROVISIONAL:`-marked. The slot is reserved (F-004) but
   its *semantics* (module vs instance vs fn split, `funcref`/`externref`
   first-classing, GC finalisation of the external `*Loaded`, auto-collect
   rooting) are owned by the Phase-16/F-004 entry, not this demo cycle — so P1
   populates the slot minimally (HeapHeader + external pointer + `null` tag_ops
   trace, the correct leaf default per F-006) and defers the structural calls to
   D-259. The external `*Loaded` is intentionally not finalised for P1 (the
   `cljw add.clj` demo is short-lived; auto-collect is off); D-259 owns
   finalisation/rooting.
5. **Verification (F-001-honest)**: the demo is verified by `zig build -Dwasm`
   + `cljw examples/wasm/add.clj` → `42`, run on demand (and at the Phase-16
   gate / pre-tag), **NOT** in the default per-commit gate — the default gate
   must never resolve zwasm. `examples/wasm/` carries the prebuilt `add.wasm`,
   its WAT source, and the repro command (PRIORITY.md P1).

## Alternatives considered

The mandatory Devil's-advocate subagent (fresh context, F-001/002/004/006
pasted) produced the following, reflected verbatim:

> **F-NNN CHECK: No alternative below requires violating any F-NNN. The
> finished-form-clean option (Alt-2) stays fully inside F-001/F-004/F-006. The
> only F-004 pressure point — the wasm-instance handle representation — is
> resolved by *deferral to the Phase-16/F-004 Group D owner*, which is what
> F-004 itself mandates ("slot allocation is owned by that Phase entry, NOT a
> demo cycle"). So there is no halt-flag here.**
>
> **(Alt-1) Smallest-diff — single `surface.zig`, zero-marshal-abstraction,
> raw boxed pointer.** One file containing everything; the marshal loop and
> box/unbox written inline next to the only caller, no `engine.zig`/`marshal.zig`.
> (a) Better: smallest possible diff; one Backend marker not three; honest about
> being a spike. (b) Breaks: directly contradicts **F-009**
> (`feature_name_consistency.md` R4: "Body inline in surface file: forbidden;
> surface is a thin wrapper over the neutral impl"); the marshal + engine
> lifecycle are neutral-impl, so inlining means the Phase-16 owner must
> *extract* them — negative work; and it scatters the provisional box, losing
> the single-swap-site guarantee. (c) Envelope: inside F-001/F-004/F-006 but
> **violates F-009** → out of the envelope on F-009 grounds.
>
> **(Alt-2) Finished-form-clean — split exactly on the Phase-16 file
> boundaries, with marshal as a neutral seam.** `engine.zig` (lifecycle, public
> fn shapes matching the structure_plan:194-195 module/instance split so
> Phase-16 is addition-not-extraction), `marshal.zig` (the load-bearing
> Value↔zwasm.Value piece, structure_plan:199), `surface.zig` (thin
> register+builtins mirroring http/server.zig:115,142-150), `wasm_handle.zig`
> (single provisional wrap/unwrap, D-259 + feature_deps + marker triad). Key
> refinement over the draft: the **F-006 allocator inject point** — `engine`'s
> `init`/`load` takes the allocator as a *named parameter* (structure_plan:192
> "cw GC allocator inject point per F-006"), never an inline `rt.gpa` grab.
> (a) Better: commits engine signatures to the Phase-16 split + makes F-006 a
> named seam from day one — both zero-extra-LOC, both what the owner would
> otherwise retrofit. (b) Breaks: marginally more up-front signature thought (not
> LOC); over-committing engine's signature to a split that may change — cheap to
> amend. No semantic risk (P1 behaviour identical). (c) Envelope: fully inside;
> F-006 seam is *more* faithful than the draft; F-004 handle deferred-to-owner.
>
> **(Alt-3) Wildcard — separate demo binary `cljw-wasm` instead of a `-Dwasm`
> flag on the main binary.** A second `b.addExecutable` sharing the cljw root
> module + the wasm surface; the default `cljw` source never references
> `build_options.wasm`. (a) Better: strongest F-001 isolation (the default
> binary's source set never mentions wasm); a named artifact demos better on
> stage. (b) Breaks: two boot-path wirings = parallel-surface drift risk (the
> single-aggregator `_host_api.zig` exists to prevent exactly this); the
> Phase-16 finished form (structure_plan:191-203) assumes `wasm` is a namespace
> in the *one* cljw runtime, so a separate binary is throwaway scaffolding the
> owner unwinds (Skeleton-that-enlarges-the-rewrite smell). The `dlopen`
> sub-variant strays furthest from F-001's "lazy build-time dep" letter.
> (c) Envelope: inside F-001 (more isolated) but off-trajectory for the
> single-runtime Phase-16 form — clean isolation bought at the cost of clean
> finished form (the F-002 concern).
>
> **RECOMMENDATION: Alt-2** (the draft, tightened on two seams). Per F-002 the
> question is not "smallest diff to `42`" (Alt-1, rejected — violates F-009) nor
> "tightest isolation" (Alt-3, off-trajectory for the single-runtime Phase-16
> form), but "which shape would the Phase-16 owner be happiest to inherit": the
> three-file split, additionally (i) committing `engine.zig`'s public signatures
> to the module/instance split so Phase-16 is addition-not-extraction, and (ii)
> making the F-006 allocator a named parameter seam. Both are zero-extra-LOC —
> finished-form fidelity, not a cycle-budget trade. On F-004 all alternatives
> correctly *defer* the NaN-box slot semantics to the owning entry; Alt-2 keeps
> that deferral honest via the single `wasm_handle.zig` swap site + D-259 triad.

**Adopted: Alt-2**, with both seam-tightenings folded in. The instinct toward
Alt-1's smaller diff is the kind F-002 forbids (F-009 surface-thinness is a
project fact, not a cycle-budget question); Alt-3's isolation is real but
off-trajectory for the single-runtime finished form.

## Consequences

- **Positive**: the CFP's central demo (`cljw add.clj → 42` calling a
  Rust/Zig-compiled wasm module) becomes a real, reproducible artifact with a
  recordable URL. The surface lands *toward* the Phase-16 finished form
  (engine/marshal/surface keep their names + responsibilities; the deferred
  Phase-16 files — linker/host_func/wasi/table/global/memory/funcref/externref/
  trap_map/pod_boundary — are pure additions). The F-006 allocator seam + the
  engine module/instance signatures are committed correctly from day one.
- **Negative / deferred (tracked)**: D-259 owns the provisional handle
  close-out (NaN-box slot semantics + GC finalisation/rooting + the
  module/instance/fn split + funcref/externref first-classing). The demo leaks
  the external `*Loaded` (acceptable: short-lived process, auto-collect off).
  The `-Dwasm` demo is not in the default gate (F-001 mandate) — it is an
  on-demand / Phase-16 / pre-tag check; `examples/wasm/README.md` carries the
  repro so it is not silently un-exercised.
- **F-001 finding-handling**: any zwasm-side bug/gap surfaced while wiring this
  is RECORDED + FED BACK via `private/notes/zwasm_v2_feedback.md` (no cljw-side
  workaround, never edit zwasm); a cljw-side bug gets a real fix + debt row.

## Affected files

- `build.zig` — `-Dwasm` option + lazy-dep-guarded `exe_mod.addImport("zwasm")`
  + `build_options.wasm`.
- `build.zig.zon` — reuses the existing lazy `.zwasm` path-dep (no change).
- `src/runtime/cljw/wasm/{engine,marshal,surface,wasm_handle}.zig` — new
  (flag-guarded).
- `src/runtime/cljw/_host_api.zig` — one `if (build_options.wasm)` register line.
- `examples/wasm/{add.wasm,add.wat,add.clj,README.md}` — the demo + repro.
- `.dev/debt.yaml` (D-259) + `feature_deps.yaml` — the provisional triad.
