# What Would It Take to Make ClojureWasm the Fastest Scripting Runtime?

> **Research report — 2026-08-06.** This document is code-change-free: it
> proposes and ranks structural levers but lands no implementation. It is the
> synthesis of six sub-reports: R0 (ClojureWasm measured anchor), R1a
> (fast-interpreter source study), R1b (dynamic-language JIT tiers), R1c (Wasm
> substrate), R1d (Clojure family speed mechanics), R1e (ClojureWit deep-read).

**Confidence labels** used on every quantitative statement:

| Label            | Meaning                                                                                                                                                  |
|------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| [MEASURED-here]  | Measured in this repository / this session (M4 Pro, ReleaseSafe, v1.9.0+ADR-0184 unless noted)                                                           |
| [MEASURED-cited] | A number the cited primary source itself measured (paper, vendor blog with data, sibling repo's committed bench results, upstream ADR with measurements) |
| [CLAIMED]        | A vendor / README / docs / comment claim, not independently re-run                                                                                       |
| [INFERRED]       | Reasoned from source structure or cross-report synthesis, not measured                                                                                   |

---

## 1. Executive summary

**The question.** ClojureWasm (`cljw`) runs the rush-hour BFS real workload in
**12.3 s** where JVM Clojure takes **1.07 s** and babashka **2.46 s** — an
**11.5× / 5× gap** [MEASURED-here] — while simultaneously *winning* 19 of 30
micro-benchmarks against the 9-target fastest-script field, with residual
micro gaps of only 1.05–1.6× vs bb/python [MEASURED-here]. What structural
changes would close the macro gap toward 1×, under cljw's standing
constraints: F-004 NaN-box with non-moving 44-bit pointers, F-006 non-moving
mark-sweep GC, F-012 dual-backend behavioral equivalence (VM production +
tree-walk oracle), the ~7.4 MB ReleaseSafe binary budget (ADR-0172/0132), and
full eval/REPL/var-redefinition dynamism preserved?

**The answer, compressed.**

1. **Constant-factor levers are exhausted.** The post-ADR-0184 campaign
   plateaued at ~12.2–12.3 s; three constant-factor experiments came back
   neutral or noise-level and are recorded as refuted (§7 Tier 0)
   [MEASURED-here]. The remaining half of the runtime is interpreter
   *structure*: dispatch ~23%, per-call binding ~16%, TLV ~8%, call machinery
   ~6.5% [MEASURED-here].
2. **The evidence across six fast interpreters (wasm3, Wren, Lua, LuaJIT,
   quickjs-ng, Janet) is unanimous**: none of them does per-call heap work or
   per-argument copying; all use "argument write position *is* the callee
   frame" layouts, replicated indirect-branch dispatch, and compile-time
   resolution instead of runtime caches (§4.1). cljw's bindCallFrame ~16% +
   call ~6.5% profile is precisely the cost every one of them designed away
   [INFERRED].
3. **The measured record says interpreters can gain +25–50% before any JIT.**
   CPython 3.11–3.14 accumulated ~50% via adaptive specialization + frame/call
   restructuring [MEASURED-cited]; Deegen's generated interpreter with inline
   caches beats LuaJIT's hand-written assembly interpreter by +28%
   [MEASURED-cited]. cljw's ~45% dispatch+call profile is exactly the shape of
   that take [INFERRED].
4. **The recommended ladder** (§7): Tier 1 — call/frame redesign (the
   ADR-0184 Alt 3 template/closure split direction) + dispatch restructuring +
   fusion + arena allocation; Tier 2 — adaptive specialization and basic
   call-site caches for protocol dispatch / var deref / keyword lookup, all
   VM-internal and F-012-compatible; Tier 3 — a Sparkplug-class baseline JIT,
   sequenced after the zwasm JIT role split (gap II × III) is decided. Tracing
   JITs and copy-and-patch are argued *against* on measured evidence (branchy
   BFS worst case; stencil pipeline and size budget mismatch) [INFERRED from
   MEASURED-cited].
5. **The triangle** (§8): ClojureWasm (native runtime that *executes* Wasm),
   ClojureWit (compiler that *emits* WasmGC components), and zwasm (the engine
   under both) are complementary, not competing — ClojureWit's own documents
   say "They compose" and "We do not write a JIT… ClojureWasm… owns its
   engine; we do not own ours". The convergence point is the WIT seam and a
   future where a ClojureWit-built component is `require`d by cljw and
   executed by zwasm's JIT.

---

## 2. What "fastest scripting runtime" means

"Fastest" is not one axis. The report decomposes it into six, each with a
current champion and its number.

### 2.1 Cold start

- **Wasm edge platforms** own this axis: Fastly Compute claims **~35.4 µs**
  instantiation (wasmtime + CoW memory images) [CLAIMED, Fastly launch
  press release] vs ~5 ms-class V8 isolates. Wizer pre-initialization snapshots give **1.35–6.00×** faster
  instantiation+initialization [MEASURED-cited, vendor]. Cloudflare Python
  Workers memory snapshots took fastapi+pydantic load from **~10 s to ~1 s**
  [CLAIMED].
- **zwasm** AOT (`.cwasm`): **2.0–2.3 ms** full-process, vs wasmtime
  6.3–7.2 ms, wasmer ~12 ms, WasmEdge ~16.5 ms [MEASURED-cited, zwasm
  docs/benchmarks.md, M4 Pro].
- **babashka**: **~10 ms** startup (GraalVM native-image) [MEASURED-cited,
  SCI ADR 0016].
- **cljw** is a native binary with a startup cache (D-140) and an AOT envelope
  restoring core bytecode — this axis is already held [MEASURED-here /
  repo SSOT].

### 2.2 Steady-state throughput

- The plb2 benchmark set (Apple M1, 2024-01) [MEASURED-cited]: nqueen — AOT
  group (C/Rust/Zig/Nim) 2.5–3 s; **Bun/Node (JSC/V8) 3.0–3.7 s**; Dart 3.62;
  Java 3.92; LuaJIT 5.31; PyPy 6.91; … Ruby (CRuby 3.3 + YJIT) 87.5; Perl 158.3;
  CPython 159.97. The JIT-tier champions are the JS engines (hundreds of
  person-years); **pure interpreters sit at ~60–64× slower than AOT**
  [MEASURED-cited] — a scale on which cljw's 11.5×-vs-JVM looks comparatively
  strong [INFERRED].
- Within interpreters, the ceiling holders are LuaJIT's interpreter and
  Deegen-generated interpreters (register bytecode + inline caches + minimal
  frames) [MEASURED-cited, §4].

### 2.3 Memory

- zwasm peak RSS **2.1–5.1 MB** vs wazero ~9 MB, wasmtime ~13 MB, wasmer
  ~27.5 MB (4–12× advantage) [MEASURED-cited, zwasm docs/benchmarks.md].
- Interpreter-side: fast VMs win memory by *allocation-rate design*, not GC
  sophistication — Wren and Janet stay fast with plain STW mark-sweep because
  numbers are immediates and frames are array slices (§4.1.7) [INFERRED].

### 2.4 Binary size / distribution

- squint's runtime is **~10 KB** [unverified]; cherry (persistent
  structures kept) starts at **~300 KB** (56 KB gzipped) [CLAIMED,
  borkdude DCD 2022 deck]; cljw ships a single **~7.4 MB**
  ReleaseSafe binary with a budget-ceiling gate (ADR-0172) [MEASURED-here];
  GraalVM Crema runtime-class-definition support was parked by SCI at
  **+115 MB** image growth (71.2→186.5 MB) [MEASURED-cited, SCI ADR].
- Distribution as *components*: a Wasm component is callable from any
  ecosystem — ClojureWit's founding observation is that "Clojure has never
  been callable *from* another language ecosystem" (§8).

### 2.5 Dynamism preserved (eval / redef / REPL)

The axis that reshuffles everything above [INFERRED, R1d §T7]:

- **babashka/SCI** keep eval by interpreting (paying 21–60× on tight loops
  [MEASURED-cited]); **ClojureDart** sells eval entirely for Dart AOT +
  tree-shaking; **CLJS** pays by mode (dev dynamic / `:advanced` static);
  **jank** keeps eval via LLVM ORC JIT and pays toolchain weight (a recorded
  1 s → 76 s startup regression under LLVM 22 [CLAIMED, jank blog]);
  **ClojureWit** is two-mode by design — "Dynamism is lost at the production
  boundary, deliberately" [primary doc, R1e]. **cljw** keeps full dynamism in
  a native runtime — the position this report treats as non-negotiable.

### 2.6 Summary table

| Axis                | Champion (2026)                | Number                                       | cljw today                          |
|---------------------|--------------------------------|----------------------------------------------|-------------------------------------|
| Cold start          | Wasm edge (Fastly) / zwasm AOT | 35.4 µs [CLAIMED] / 2.0 ms [MEASURED-cited]  | Native + startup cache: held        |
| Throughput (macro)  | V8/JSC                         | plb2 nqueen 3.0–3.7 s [MEASURED-cited]      | 11.5× vs JVM clj [MEASURED-here]   |
| Throughput (interp) | LuaJIT interp / Deegen         | Deegen +28% over LuaJIT asm [MEASURED-cited] | micro 19/30 wins [MEASURED-here]    |
| Memory              | zwasm                          | RSS 2.1–5.1 MB [MEASURED-cited]             | NaN-box + 3-tier alloc              |
| Binary size         | squint (~10 KB) [unverified]   | —                                           | ~7.4 MB ReleaseSafe [MEASURED-here] |
| Dynamism            | bb / cljw (full eval)          | —                                           | full (eval, REPL, redef)            |

---

## 3. Where ClojureWasm stands today

All facts in this section are the R0 anchor: measured this session or
confirmed from in-repo SSOT [MEASURED-here unless noted].

### 3.1 The headline numbers

- rush-hour BFS `(g/generate 7 :medium)`: **12.3 s** (ADR-0184's own
  landing: 16.5 → 12.3 s, **−26%**; cumulative campaign arc from v1.9.0:
  17.9 → 12.3 s, **−31%**). Same workload: **clj (JVM) 1.07 s, babashka
  2.46 s** → cljw is currently **11.5× vs clj, 5× vs bb** [MEASURED-here].
- fib 32 (call-heavy micro): **~460 ms** [MEASURED-here].
- fastest-script 9-target suite (D-450 barrier): **19/30 wins** as of
  2026-06-24; remaining gaps vs bb/python are **1.05–1.6×** [MEASURED-here].
- **The essential finding: micro is already competitive; only the real
  workload (rush-hour) shows 11.5×.** The micro/macro divergence is the
  problem statement itself.

### 3.2 Post-ADR-0184 profile (sample-based, 13.1 s run) [MEASURED-here]

| Bucket                                                    | Share |
|-----------------------------------------------------------|-------|
| vm.eval dispatch (incl. inlined stepOnce)                 | ~23%  |
| tree_walk.bindCallFrame (per-call bind)                   | ~16%  |
| dyld TLV (`_tlv_get_addr`)                                | ~8%   |
| Call machinery (treeWalkCall/calleeFrame/checkArity etc.) | ~6.5% |
| GC (collectStopTheWorld)                                  | ~3.8% |
| malloc/memset/memmove                                     | ~4%   |
| free_pool hashmap lookup                                  | ~2.2% |
| equal/hash                                                | ~2.5% |
| seq fns + lazy_seq                                        | ~2.3% |
| Collections (nth/get/assoc family)                        | ~2%   |

Roughly **half the runtime is "turning instructions and calling functions"**
(dispatch + bind + TLV + call ≈ 45%+); GC is a modest 3.8% [MEASURED-here].

### 3.3 Refuted experiments (do not re-run)

- TraceRef per-call TLV cache — **neutral** [MEASURED-here].
- GC threshold multiplier 2×→4× — **neutral** [MEASURED-here].
- bindCallFrame selective nil-init — **−0.6%, noise-level** [MEASURED-here].
- Adopted: O-055 budget-TLV hoist — **−2.3%** [MEASURED-here].
- Adopted: ADR-0131 2a operand arena — a **~25% win** (fib 56→41 ms, reused
  warm arena vs cold fresh host arrays) — landed [MEASURED-here].
- D-386 standing results: stepOnce-prologue safety-point polls are
  **near-free**; ADR-0131 2b call-flatten **neutral**; the ARM64 JIT
  substrate (ADR-0151) is execution-verified but its call-ABI micro-lever
  was **rejected at a ~3–4.5% ceiling** [MEASURED-here].
- **Lesson: constant-factor levers plateau at ~12.2 s. What remains is
  structure** — dispatch (superinstruction/fusion/JIT) and call-machinery
  redesign [MEASURED-here, R0's own conclusion].

### 3.4 The architectural constraints any lever must respect

- **F-004**: NaN-box, 64 slots (4 groups × 16), 44-bit pointers, pointer
  identity assumes a **non-moving** heap.
- **F-006**: mark-sweep + 3-tier allocator, **non-moving** GC; the zwasm heap
  is separate.
- **F-012**: production backend = VM (bytecode); tree_walk is the differential
  oracle; behavioral equivalence of both backends is the correctness keystone
  (F-011).
- **ADR-0184**: Function = variable-length GC cell (methods+bindings inline);
  **Alt 3 (template/closure split) is the named finished form**.
- **zwasm ADR-0200**: zwasm is growing a JIT-backed engine; cljw's
  north star = gap II (Wasm interop) × gap III (VM-perf fusion→JIT). SSOT:
  `.dev/zwasm_capabilities.md`.
- **Binary budget**: ADR-0172, shipped ReleaseSafe ~7 MB with a ceiling gate;
  ReleaseSafe is fixed policy — safety is not traded for size/speed
  (ADR-0132).
- **Startup**: D-140 startup-cache family; AOT envelope (core bytecode
  restore) landed; cold-start details tracked in the O-series ledger.

---

## 4. How the fast ones do it

### 4.1 The interpreter ceiling — six VMs read at source level

R1a read wasm3, Wren, Lua (PUC 5.5-dev @ 7579fc9), LuaJIT (@ 1edc3e52b),
quickjs-ng (0.16.1 @ 954dc53), and Janet (@ f362e8f) from shallow clones
(2026-08-05/06 HEAD, `~/Documents/OSS/`). One-page summary:

| VM              | Dispatch                           | Value repr                                  | Call core design                                       | IC/shape                                 | GC                            |
|-----------------|------------------------------------|---------------------------------------------|--------------------------------------------------------|------------------------------------------|-------------------------------|
| quickjs-ng      | computed goto (toggle)             | 64-bit tagged union / NaN-box (32-bit only) | alloca-like var_buf on C stack                         | Shape sharing (IC removed)               | RC + cycle collector          |
| Lua             | computed goto (toggle)             | 16-byte TValue (union+tag), int/float dual  | CallInfo reuse + re-entry in one C frame (`startfunc`) | none (table-flags negative cache)        | incremental + generational    |
| LuaJIT (interp) | hand-written asm, direct threading | NaN-tagging (LJ_GC64: 47-bit ptr)           | frame link inside Lua stack, no C frame                | none (HREFK in traces)                   | incremental M&S, non-moving   |
| Janet           | computed goto (toggle)             | NaN-box 64                                  | frame slices in a fiber's contiguous stack             | none                                     | mark-sweep + pressure counter |
| Wren            | computed goto (toggle)             | NaN-box 64                                  | CallFrame array + arg window = callee frame            | unnecessary (global method-symbol table) | mark-sweep                    |
| wasm3           | **tail-call threading (M3)**       | typed untagged 64-bit slots                 | slot offsets fixed at compile time, chained C calls    | n/a                                      | n/a (linear memory)           |

Three invariants hold across all six, mapping directly onto cljw's profile
(dispatch ~23% + per-call bind ~16%):

**Law 1 — per-call work is pointer arithmetic plus a few stores; nobody
allocates a frame as a GC cell.** [INFERRED from source, per-VM verified]

| VM         | Real per-call cost                                                                | Where the frame lives                                    |
|------------|-----------------------------------------------------------------------------------|----------------------------------------------------------|
| Lua        | ci bump + 4 stores + nil-fill + 1 compare                                         | reused CallInfo list + contiguous value stack            |
| LuaJIT     | load + typecheck + lea + PC store + dispatch                                      | 2 slots inside the Lua stack (frame type in PC low bits) |
| quickjs-ng | alloca ×1 + locals undef-fill (**args alias caller slots**)                      | C stack                                                  |
| Janet      | 3 compares + nil-fill + 5 stores (**push target IS the new frame**)               | slice of the fiber's contiguous array                    |
| Wren       | 3 stores + numFrames++ (**arg window = callee frame**)                            | grow-only array in ObjFiber                              |
| wasm3      | `sp += stackOffset` + C call (**args written into callee slots at compile time**) | native C stack + slot array                              |

Common shape: (a) **arguments are never copied — the caller's write position
is designed to be the callee's frame**; (b) frame metadata is 3–5 words; (c)
the stack is a growable contiguous region with a 1-compare growth check.
This table *is* the answer to cljw's `bindCallFrame ~16% + call ~6.5%`
[INFERRED].

**Law 2 — numbers, booleans, nil are heap-free immediates, copied as 8 or 16
bytes.** NaN-box (LuaJIT/Janet/Wren; cljw's F-004 is the same family) vs
16-byte tagged union (Lua/quickjs-ng) is secondary; what matters is that the
arithmetic fast path is allocation-free with a 1–2 instruction tag check.
quickjs-ng shows that **tag-number design alone** buys single-instruction
checks: `JS_TAG_INT == 0` makes both-int testing `(tag1|tag2)==0`; refcounted
tags all negative makes `HAS_REF_COUNT` one unsigned compare; truthy tags
contiguous at 0..3 collapses truthiness to one compare (tag enum
quickjs.h:~180-215, `JS_TAG_INT = 0` at quickjs.h:191; fast paths
quickjs.c:19209, 20123-20159) [INFERRED from source]. This
pattern has direct application room in cljw's NaN-box slot layout (F-004's 4
groups × 16) [INFERRED].

**Law 3 — dispatch = replicated indirect branches + VM registers pinned in
locals.**

- Replicating the indirect-branch site at the end of every handler (Lua
  `vmbreak` re-inlining fetch+dispatch, ljumptab.h:8-17; quickjs `BREAK =
  SWITCH(pc)`; LuaJIT replicated `ins_NEXT`; Wren `DISPATCH()`): the
  **hardest number in any of the six repos** is LuaJIT's comment that sharing
  a single dispatch site instead is "**Around 10%-30% slower on Core2, a lot
  more slower on P4**" — scoped by its own qualifier "affects only certain
  kinds of benchmarks (and only with -j off)" (vm_x64.dasc:221-237)
  [CLAIMED, in-repo].
- ip/base/(k) pinned in C locals (or physical registers), memory write-back
  only "just before anything that can error" (Lua `savepc`, Janet
  `vm_commit`, Wren `STORE_FRAME` = one store, wren_vm.c:826-862).
- Two levels above that: (i) **wasm3's tail-call threading** — `musttail` +
  fixed signature binds VM registers 1:1 to physical registers
  (m3_exec_defs.h:19-63, m3_config_platforms.h:94); a bitwise-or op compiles
  to 5 instructions (docs/Interpreter.md:88-106) [MEASURED-cited, in-repo
  disassembly]. Zig can express the same shape via `@call(.always_tail)`
  [INFERRED]. (ii) LuaJIT's hand-written assembly, whose essential advantage
  is escaping the C compiler's alias conservatism (BASE/PC reloaded per
  handler otherwise) [CLAIMED, Mike Pall].

Per-VM highlights that carry over to §7:

- **wasm3** (the cleanest isolation of dispatch+call+registerization, since
  it has no dynamic dispatch and no GC): CoreMark 1.0 score **1627.9** —
  **8.1× wasm-micro-runtime, 57× Node's interpreter, 1/11.8 of native GCC,
  1/4 of wasmtime/Cranelift JIT** (docs/Performance.md:4-20)
  [MEASURED-cited, in-repo]. Mandelbrot: 4.4× slower than GCC -O3, ~6.8×
  faster than a Lua hand-port (docs/Interpreter.md:25-31); "4-15× slower
  than compiled" band, "3×+ vs Lua" [CLAIMED, in-repo]. `op_Call`
  (m3_exec.h:542-565) is `sp = _sp + stackOffset; Call(...)` — zero per-call
  heap work, zero arity checks (types pre-validated). `op_Entry`
  (m3_exec.h:802-860): bounds check → locals memset → const memcpy. Lazy
  compile self-patches the code stream (`op_Compile` → `rewrite_op(op_Call)`,
  m3_exec.h:778-798). Compile-time stack→register-file conversion
  (docs/Interpreter.md:63-67, m3_compile.c:339-431) with `_rs/_ss/_sr`
  operand-location variants (m3_exec.h:125-147); fusion exists, effect
  "sometimes" [CLAIMED]. Loops unwind the native stack by returning the loop
  pc (m3_exec.h:864-895).
- **Wren**: the compiler interns full signatures (`"int(_,_)"`, arity
  included) into **VM-global integer symbols** (wren_compiler.c:1853-1938);
  `ObjClass.methods` is a flat array indexed by symbol — method dispatch is
  **bounds check + one array index**, no hashing, no inheritance walking, no
  IC needed (wren_vm.c:982-1043; design comment wren_value.h:392-416).
  Inheritance is **copy-down** at class definition (wren_value.c:62-84) —
  affordable because classes are sealed. Fields are fixed offsets with
  `numFields` known at compile time (bytecode patched for subclasses,
  wren_compiler.c:3849-3898). There are **no arithmetic opcodes** — `+`,
  `<`, `[]` are all method calls, made viable by `METHOD_PRIMITIVE` returning
  **without pushing a CallFrame** (wren_primitive.h:38-44). Computed goto is
  worth **5-10%** by the author's measurement
  (doc/site/performance.markdown:218) [CLAIMED]; the 2014 comparison table
  shows Wren's Method Call bench at 0.12 s **beating LuaJIT -joff at 0.16 s**
  (the only clean win; LuaJIT with JIT on "beats everyone") [CLAIMED].
  Closures are Lua-style open/close upvalues — **no copy at capture time**
  (wren_vm.c:244-283, 287-301), in direct contrast to cljw's snapshot copy.
- **Lua (PUC)**: the "zero per-call work" textbook. `OP_CALL`
  (lvm.c:1726-1741) does `ci = newci; goto startfunc;` — **no C recursion;
  any depth of Lua→Lua calls lives in one C frame**. CallInfo nodes are
  **reused, not freed** (`next_ci`, ldo.c:621): malloc happens only past the
  depth high-water mark. `vmfetch()` (lvm.c:1191-1197) folds hook/stack-
  reallocation detection into **one predicted-not-taken `trap` flag branch**.
  Register VM (iABC, 7-bit opcode, ~85 opcodes; lopcodes.h:14-37): `a=b+c*d`
  is 2 instructions vs ~7 on a stack VM. The **slow-path-as-separate-
  instruction pattern**: the compiler always places `OP_MMBIN` after
  `OP_ADD`; the fast path *skips it* with `pc++` (lvm.c:998-1004) — unused
  metamethod dispatch costs not even a branch. This is directly importable
  into cljw's dispatch design [INFERRED]. Upvalues: shared per-captured-
  variable boxes, access is **branchless single indirection** open or closed
  (lobject.h:680-693, lfunc.c:87-99, 197-211); functions that capture
  nothing pay nothing at scope exit. Lua 5.4+ generational mode represents
  generations as **pointer boundaries within the single allgc list** — no
  nursery, no copying, no forwarding = **generational while non-moving**
  (lgc.c:1335-1381), the reference implementation compatible with cljw's
  F-006 [INFERRED]. Its "IC" is the `Table.flags` metamethod-absence negative
  cache (ltm.h:49-68): one bit test replaces the whole `__index` lookup. The
  repo commits **no benchmark data at all**; all Lua speed attribution here
  is [INFERRED].
- **LuaJIT**: DynASM-generated direct threading; `ins_NEXT` is 6
  instructions on x64 (vm_x64.dasc:211-219). Fixed register allocation:
  BASE/KBASE/PC/DISPATCH in callee-saved registers; ARM64 burns **three
  callee-saved registers as constants** (TISNUM/TISNUMhi/TISNIL) making type
  checks one reg-reg compare (vm_arm64.dasc:28-42). The DISPATCH register
  doubles as the base for global state/hot counters (lj_dispatch.h:90-124) —
  enabling hooks/JIT by table-entry rewrite at zero steady-state cost. 8-byte
  NaN-tagged values (lj_obj.h:173-213): half PUC's memory traffic; tag
  numbering descending from `~0u` so order predicates collapse to one
  unsigned compare; x64 defaults to double-only while ARM64 runs
  dual-number mode (int+double — the burned TISNUM registers are its
  integer tag); the narrowing essay (`lj_opt_narrow.c:22-60`: int narrowing
  "doesn't pay in an interpreter") explains why doubles suffice on
  x64-class hardware. Calls: return PC and
  callee GCfunc are two ordinary stack slots (lj_frame.h:15-45); the entire
  call is load + typecheck + lea + PC store + dispatch (vm_x64.dasc:240-253);
  stack check and nil-fill are the callee's `BC_FUNCF` header opcode's job.
  JIT: hashed hot counters (hotloop=56); fold/CSE/forwarding run **at IR emit
  time** (`emitir`); copy-substitution loop unrolling hoists invariant guards
  (lj_opt_loop.c:22-90, design essay: traditional LICM is nearly powerless in
  guard-dense dynamic IR) [CLAIMED, in-repo]; **HREFK** specializes
  constant-key table lookups to "hmask guard + fixed-offset load"
  (lj_record.c:1493-1510) — hidden-class effect without a shape machinery,
  trace-local. GC is incremental M&S and **non-moving** (traces hold raw
  pointers). Note: the folk number "LuaJIT interpreter is 2–4× PUC Lua" is
  **not in the repository** — treat as external [CLAIMED].
- **quickjs-ng**: computed goto with a compiler denylist (quickjs.c:51-55);
  dispatch table padded to 256 entries so the bounds check vanishes
  (`*pc++` unconditional index, quickjs.c:18079-18095); interrupt polls only
  on backward branches and call entry (quickjs.c:8684-8690, init 10000) —
  the same design cljw already measured as near-free [MEASURED-here,
  D-386]. JSValue on 64-bit is a **16-byte tagged union** with doubles
  inline (no heap floats). Hand-written int fast paths for
  add/sub/mul/inc/dec/compare (quickjs.c:20123-20159, 20642-20667). Calls:
  the frame is a C-stack local, one `alloca`
  (quickjs.c:18065, 18135-18180); operand stack depth is compile-time
  (`compute_stack_size`) so pushes have no bounds check; **`arg_buf =
  (JSValue *)argv`** — when argc suffices, caller operand-stack slots are
  aliased as the callee's args: zero copy, zero refcount bumps, zero
  zero-fill. Closures: `JSVarRef` open/close (quickjs.c:469-495); capture is
  an O(1) array index; `close_var_refs` runs only if `var_ref_count != 0`.
  **Shapes exist but inline caches do not**: `docs/docs/diff.md:45` still
  advertises "Polymorphic inline caching", but **0.16.1 has no IC** (grep
  clean, no ic.c, no `_ic` opcodes — removed; the doc is stale) [CLAIMED →
  verified stale]. Property access is a per-access bucket walk; the dense-
  array full bypass (`p->u.array.u.values[idx]` + class_id/idx guard,
  quickjs.c:19878-19900) plausibly matters more in practice [INFERRED].
  Refcounts moved into the **allocator block header** (quickjs.c:286-298),
  saving 8 bytes per object; an **arena allocator** (31 size classes
  16..512 B, 4 KB arenas, intrusive free lists, quickjs.c:258-320,
  1709-1900) makes malloc ~5 instructions. Opcode fusion exists where
  profiling justified it: `OP_get_loc0_loc1` ("individually very frequent
  AND often paired", quickjs.c:18957-18959), `OP_add_loc`, `OP_call0..3`.
  Anti-finding worth stating: **no JIT, no IC, no generational GC, no real
  tail calls, no type feedback** — and it is still among the fastest C
  interpreters. The reproducible story is "cheap dispatch + allocation-free
  numbers + hand-written fast paths" [INFERRED].
- **Janet** (the Lisp VM closest to cljw): computed goto
  (vm.c:53-72); **GC-poll opcode selection** — `vm_pcnext()` (no poll) vs
  `vm_checkgc_pcnext()` (1 compare) chosen per opcode, so pure register ops
  pay zero GC checks (~1/3 poll) (vm.c:93-97). NaN-box 64 but **all numbers
  are doubles** — no int payload; integer-domain ops pay range-check +
  double↔int32 round trips (vm.c:141-205, janet.h:785-805) — the part cljw
  must *not* copy (F-005 requires the integer tower) [INFERRED]. **Calls:
  the fiber's single growable `Janet*` stack; frame = a slice; the frame
  header (4 Janet-widths) sits directly under the register window**
  (janet.h:975-1013, fiber.c:191-244). Full call prologue: 2 arity compares
  + 1 capacity compare + nil-fill of unused slots (the only O(frame) cost —
  a GC-correctness requirement) + 5 header stores. **Argument copying is
  zero**: the caller's `JOP_PUSH` destination (`stackstart`) *becomes* slots
  0..n-1 of the new frame. `JOP_TAILCALL` reuses the frame with one memmove
  — true TCO (fiber.c:330-393); return is 3 assignments. Closures: one lazy
  `JanetFuncEnv` per frame aliasing the fiber stack; on frame death,
  `janet_env_detach` (fiber.c:253-281) copies the frame once, nil-ing
  non-captured slots via a compile-time `closure_bitset` — capture-time copy
  is zero (vs cljw's per-closure snapshot copy); the cost moved to one copy
  at escape. **No IC — and the reason is instructive: `def` bindings are
  burned into function defs as constants at compile time**
  (compile.c:307-397): calling a core function is one `LOAD_CONSTANT`; vars
  lower to a 1-element array deref. This is the proven pattern corresponding
  to cljw's Var-deref + TLV (~8%) path [INFERRED]. Keywords/symbols intern
  with precomputed header hash (janet.h:1804). Structs use Robin-Hood open
  addressing with order-independent layout (struct.c:71-133) but **no
  structural sharing** — assoc copies everything (no HAMT): Janet's
  immutable values are for reading, not incremental update — an explicit
  counter-verdict for Clojure-style allocation-heavy workloads [INFERRED].
  No benchmarks in the repo; all Janet attribution is [INFERRED].

**Fast/slow path separation practice** (the structural lever inside the ~23%
dispatch bucket): Lua relocates slow paths into separate skipped
instructions (OP_MMBIN); quickjs-ng keeps hand-written int fast paths inline
and slow paths out-of-line (I-cache); LuaJIT/wasm3 kill runtime branches
with operand-kind-specialized opcodes (ADDVN/ADDNV/ADDVV, `_rs/_ss/_sr`);
superinstructions exist where "frequent AND paired" was profiled (quickjs
`OP_get_loc0_loc1`, Wren `LOAD_LOCAL_0..8`/`CALL_0..16`, wasm3 fused ops).

**The truth about IC/shape at the interpreter level: none of the six ships a
runtime IC today** (quickjs-ng removed its). The alternative-strategy ladder,
in order of preference [INFERRED]:

1. **Compile-time resolution** (Janet def burning / Lua k-index / wasm3 slot
   fixing) — delete the lookup itself.
2. **Interning + precomputed hash** (Lua short strings / Janet keywords /
   LuaJIT strings) — equality becomes pointer comparison.
3. **Negative caches** (Lua Table.flags) — remember absence in one bit.
4. **Flat tables bought with language constraints** (Wren's global symbol
   table + copy-down + sealed classes).
5. **Shape sharing** (quickjs-ng) — decompose per-object hash maps into a
   shared name table + flat value array (valuable even without IC).
6. **Trace-local specialization** (LuaJIT HREFK).

Implication for cljw: before adding IC to keyword lookup / protocol dispatch
/ var deref, check the remaining room for lookup-*deletion* levers of kinds
(1)(2)(3) [INFERRED].

**Closure capture, three schools**:

| Scheme                                   | At capture                          | At escape                     | At read                   |
|------------------------------------------|-------------------------------------|-------------------------------|---------------------------|
| Lua/LuaJIT/Wren/quickjs (upvalue/varref) | 1 box per variable (shared, reused) | per-variable close (in place) | 1 indirection, branchless |
| Janet (frame env)                        | 1 env per frame (lazy)              | 1 whole-frame copy            | branch + double index     |
| cljw (snapshot copy, R0/ADR-0184)        | value copy per closure              | —                            | direct                    |

Clojure bindings are immutable, so shared-mutable machinery is semantically
unnecessary — but the shared lesson is "**do not copy per-closure ×
per-var at capture time**" (shared env / shared box / template-closure split
— the direction of ADR-0184 Alt 3's named finished form) [INFERRED].

**GC's place**: Wren and Janet stay fast with naive STW mark-sweep because
Laws 1–2 keep allocation rates low (cljw's GC is likewise only ~3.8%
[MEASURED-here]). The only generational implementation (Lua 5.4+) achieves
minor collection **without moving** — compatible with F-006. quickjs-ng's
arena (31 size classes, 4 KB, intrusive free lists) is the direct recipe for
cljw's malloc/memset ~4% + free_pool ~2.2% [INFERRED].

**R1a's one-to-one answer to the cljw profile**:

| R0 profile bucket         | Share | Proven counter-move from the six VMs                                                                                                                                     |
|---------------------------|-------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| vm.eval dispatch          | ~23%  | Replicated indirect branches (10–30% class [CLAIMED]) → tail-call threading (wasm3 model, Zig `@call(.always_tail)`) / operand-specialized opcodes / superinstructions |
| bindCallFrame             | ~16%  | "arg write position = callee frame" layout + frame reuse (6/6 unanimous) — delete per-call copy and init structurally                                                   |
| dyld TLV                  | ~8%   | Janet-style compile-time resolution — reduce the *count* of lookups, not their unit cost                                                                                |
| Call machinery            | ~6.5% | Callee-header opcode (LuaJIT BC_FUNCF) / arity folded into the opcode (Wren CALL_n)                                                                                      |
| malloc/memset + free_pool | ~6%   | quickjs-ng arena (size-class free lists)                                                                                                                                 |
| GC                        | ~3.8% | Lua-style non-moving generational (F-006-compatible) — low priority                                                                                                     |

### 4.2 The IC/shape layer — the most cross-cutting single technique

Lineage: Smalltalk inline caches (Deutsch–Schiffman 1984) → Self's PICs +
maps (Hölzle et al. 1991) → shapes/ICs in every modern JS engine (canonical
explainer: mathiasbynens.be/notes/shapes-ics). Measured evidence:

- Serrano & Feeley, "Property Caches Revisited" (CC 2019): improved
  property caches cost nothing when unused and gain **up to ~4×** on
  cache-miss-heavy benchmarks (deltablue 157.9 → 39.6 s), with near-zero
  change elsewhere [MEASURED-cited].
- **Deegen / LuaJIT Remake** (sillycross, 2022-11-22): an interpreter
  *auto-generated from C++* beats **LuaJIT's hand-written asm interpreter by
  +28% average and PUC Lua by +171% (31 of 34 benchmarks)**
  [MEASURED-cited]. A major share of the win is **interpreter-internal
  inline caching** (hidden class cached in the bytecode, table access
  becomes inline-storage direct reads) — evidence that IC + frame/dispatch
  design, not hand-written assembly per se, is the essence, and that **IC
  pays with no JIT at all**.
- Negative result, load-bearing: "An Attempt to Catch Up with JIT Compilers:
  The False Lead of Optimizing Inline Caches" (arXiv 2502.20547, 2025) — in
  the AOT JS compiler Hopc, polishing ICs further (fewer memory reads)
  **did not speed anything up**; on modern out-of-order CPUs, reducing
  instruction counts/loads past the basic form does not shorten runtime.
  **IC delivers most of its win in its basic form** [MEASURED-cited].
- Synthesis [INFERRED]: the first IC step (megamorphic lookup → monomorphic
  direct path) changes the order of magnitude; JIT codegen's *additional*
  contribution is dispatch/decode removal + typecheck removal + register
  allocation. An IC-less JIT is weak (V8 gains only +5–15% from Sparkplug
  *because* ICs were already complete); an IC-ful interpreter closes much of
  the JIT gap (LuaJIT interp, Deegen).
- Mapping to cljw [INFERRED]: the analogues of JS property access are (a)
  protocol/multimethod dispatch, (b) Var indirection, (c) keyword lookup on
  persistent maps. Persistent maps are structurally shared rather than
  shape-mutated, but the locality assumption — the same call site sees
  same-shaped maps — holds, so call-site caches (key → storage slot / hash
  path shortcut) are viable.

### 4.3 Tiering — what each tier measurably buys

#### CPython 3.11→3.14: "+50% with no machine code" [MEASURED-cited]

- **PEP 659 specializing adaptive interpreter (3.11)**: 3.11 is **1.25×
  (25%) average over 3.10, 10–60% workload-dependent** (pyperformance)
  [MEASURED-cited, official whatsnew]. No machine code: bytecode rewrites
  itself to specialized forms at runtime (quickening + adaptive
  specialization) and de-specializes on miss. PEP text: up to 50% in
  experiments, 25% worthwhile [CLAIMED]; 25–30% of executed instructions are
  specializable [MEASURED-cited]. Per-instruction gains: binary ops up to
  10%; subscript 10–25%; calls 20%; method calls 10–20% [MEASURED-cited].
- **Call/frame structural reform contributed on par with specialization**:
  "cheaper, lazy Python frames" **3–7%** on pyperformance; "inlined Python
  function calls" (no C stack for Python→Python) **1.7× on recursion micros,
  1–3% overall** [MEASURED-cited].
- Subsequent interpreter-only gains: 3.12 +4%, 3.13 +7%, 3.14 ~+8% —
  cumulative **~50% in under four years**, 93% of benchmarks improved
  [MEASURED-cited, LWN 2025-07].
- **3.13 experimental copy-and-patch JIT**: the micro-op interpreter alone is
  **~20% slower** (more dispatch); enabling the JIT gets back to
  **"basically 0% slower"**; memory +1% (trace) / +10% (JIT); implementation
  ~1000 lines build-time Python + ~100 C + ~400 runtime C + ~9000 generated
  [MEASURED-cited, Bucher via LWN 977855]. 2025 status: 3.15-dev JIT at
  **geomean 4–12%** over interpreter [CLAIMED, PEP 836 — "about 4-12%
  geometric mean … across measured Tier 1 platforms"], still off by
  default; open problems: stack unwinding, free-threading, **code
  duplication on branchy traces**, staffing [CLAIMED, LWN 1029307 /
  PEP 836].
- The Xu & Kjolstad copy-and-patch paper itself (OOPSLA 2021): compile
  **100× faster than LLVM -O0 / ~1000× than -O2-class**, code **+14% vs
  -O0**, ~10× over an interpreter; on Wasm, vs the Liftoff baseline
  compiler: **4.9–6.5× faster compile, 39–63% faster code**
  (CoreMark/PolyBenchC) [MEASURED-cited]. The CPython ±0% vs paper 10× gap
  is explained by (a) PEP 659 having already specialized what the JIT would
  win, (b) first repaying the 20% micro-op penalty [INFERRED, R1b].
- **3.14 tail-call interpreter — the corrected story**: initial announcement
  **10–15%**; Nelhage's re-measurement showed the baseline computed-goto
  build was suffering an **LLVM/clang 19 tail-duplication regression
  (~9–12%)** (332 indirect jumps merged into 3, wrecking branch prediction);
  compared on healthy compilers, the true tail-call gain is **~1–5%**, and
  on clang-19 a plain **switch is on par with computed goto**
  [MEASURED-cited, blog.nelhage.com 2025-03]. Author Ken Jin published a
  correction: **geomean 3–5%** [MEASURED-cited, corrected]. Implication for
  cljw: dispatch-mechanism *replacement* alone (tail-call/goto/switch) caps
  at low single digits — fully consistent with R0's "stepOnce-prologue
  constant factors plateaued" [INFERRED].

| CPython tier           | Measured gain                             | Complexity cost                                                      |
|------------------------|-------------------------------------------|----------------------------------------------------------------------|
| PEP 659 specialization | +25% avg (3.11) [MEASURED-cited]          | Medium: per-family specialization + deopt; no machine code, portable |
| Frame/call reform      | 3–7% + 1–3% [MEASURED-cited]            | Medium: full frame-representation change                             |
| Tail-call dispatch     | 3–5% geomean [MEASURED-cited, corrected] | Small; clang-dependent (musttail), results vary by compiler          |
| Copy-and-patch JIT     | ~0% (3.13) → 4–12% claim                | Medium-large: build pipeline + stencils + unwind/debugger debt       |

#### Ruby: YJIT (LBBV) and ZJIT

- **YJIT** (lazy basic-block versioning, Chevalier-Boisvert): compile basic
  blocks lazily at first reach, versioned by type context — type checks
  dissolve naturally; fast warmup, ~100% compatibility. VMIL 2021:
  railsbench +20%, liquid +39%, activerecord +37% [MEASURED-cited]. Ruby 3.2
  (Shopify, 2023-01-17): **railsbench +38% over interpreter; production
  Storefront Renderer e2e request time −5–10%**; memory overhead cut to
  ~1/3 of 3.1 [MEASURED-cited]. The MPLR 2023 production-context paper
  reports significant speedups on real-scale benchmarks (abstract-level;
  the commonly quoted **15–19%** is [unverified] — paper body
  inaccessible).
- The micro-vs-production divergence (2–3× micro vs 5–10% prod) is the
  mirror image of cljw's (micro competitive, macro 11.5×): **JIT gain is
  proportional to interpreter residency**. Rails production spends its time
  in C methods/I-O/GC; cljw's rush-hour burns ~45% in dispatch+call, so the
  attackable region is *large* [INFERRED, R1b].
- **ZJIT** (merged 2025-05-14, experimental in Ruby 4.0, 2025-12-25):
  abandons LBBV for a **method-level SSA HIR + interpreter profiling** —
  official reasons: raise the ceiling, be a more traditional compiler for
  contributors [CLAIMED]. At 4.0 launch: "faster than the interpreter, not
  yet at YJIT parity"; not production-recommended; no headline percentage
  published (the launch post shows rubybench charts only) [CLAIMED]. Lesson for a solo developer: the world's best-resourced Ruby
  JIT team concluded LBBV is quick to build and fast, but loses on ceiling
  and maintainability [INFERRED].

#### V8 / JSC — what a baseline tier costs and buys

- **Sparkplug** (2021): no IR; one linear pass over bytecode emitting canned
  machine code per opcode ("a switch inside a for loop"); **keeps the
  interpreter's exact stack-frame layout** so OSR/debugger/profiler/deopt
  are nearly free; complex operations call prebuilt builtins; the entire win
  is "dispatch + operand decode removal". Measured: **Speedometer +5–10%;
  real-browsing V8 main-thread time 5–15%** [MEASURED-cited, v8.dev].
  Ordering matters: this is the increment on a system that already has
  IC/shapes/optimizing JIT — an IC-less system adding a baseline JIT gains
  much more (copy-and-patch's ~10× over interpreter is the upper-side
  anchor) [INFERRED].
- **Maglev** (2023, mid-tier SSA): compiles ~20× slower than Sparkplug,
  10–100× faster than TurboFan; JetStream **+8.2%**, Speedometer **+6%**,
  −10% V8 energy on Speedometer [MEASURED-cited].
- **JSC**: LLInt → Baseline (bytecode template JIT, the Sparkplug
  prior art) → DFG (fires at 60 calls or 1000 loop iterations; ~4× Baseline
  compile cost) → FTL (~6× DFG) [CLAIMED, webkit.org / docs.webkit.org].
  Four tiers means four reimplementations of the language's semantics — the
  DRY violation that motivated Truffle (PLDI 2017 paper's framing).

#### LuaJIT / Deegen, and why tracing is out for cljw

- LuaJIT interpreter speed per Mike Pall: hand-written asm (C compilers
  collapse on huge switch loops — register allocation and hot/cold layout
  degrade), register bytecode, NaN-tagging + dual numbers [CLAIMED, Pall's
  lua-l post "Why is LuaJIT's interpreter fast?" (2011-02); HN 8605225 is
  secondary discussion / luajit.org].
- Deegen (§4.2) is the modern refutation that the *hand-written asm* part is
  essential: generated code + interpreter IC beat it [MEASURED-cited].
- **Tracing weaknesses, primary-source**: PyPy's Bolz-Tereick (2025-01):
  "bytecode interpreters and extremely unpredictable branchy code generally
  perform badly under tracing JITs" — the loops-take-similar-paths premise
  collapses; and "whether one should pick tracing given enough developers is
  highly unclear; for PyPy's meta-JIT it was a labor-saving device"
  [CLAIMED, primary]. Trace explosion case study: email-header parsing
  specialized per occurrence order; "the JIT code was faster but memory grew
  faster; at equal memory, running parallel non-JIT interpreters won"
  [CLAIMED, LWN 1029843 (2025) — a primary anecdote, not a published
  measurement]. CPython's own trace-based JIT lists
  branchy-code duplication as unresolved [CLAIMED, LWN 1029307].
- rush-hour BFS — data-dependent branches differing every iteration — is the
  tracing worst case. **If cljw ever compiles, it should be method/block
  shaped (LBBV or baseline template), never tracing** [INFERRED].

#### The counter-axes: Truffle partial evaluation, AOT dynamic languages

- **GraalVM/Truffle** (PLDI 2017): write the interpreter once, derive
  optimized code by partial evaluation — **Graal.js = 0.83× V8, TruffleRuby
  = 3.8× JRuby, FastR = 5× GNU R** [MEASURED-cited]. Preconditions are
  enormous (Graal compiler + HotSpot-class GC + tens of person-years; long
  warmup; a user benchmark report (oracle/graaljs#879) shows GraalJS ~40%
  behind V8 on Octane overall). Method-incompatible with a solo developer + 7 MB
  budget [INFERRED] — but its motive ("implement semantics once") is the
  same problem F-012 answers with equivalence testing instead [INFERRED].
- **SBCL / Chez Scheme**: AOT-native dynamic languages at "not hand-C, but
  fast for dynamic types + GC + safety" level; Chez tends to win at default
  settings, roughly tied with optimization declarations [CLAIMED, community
  measurements, elmord.org 2019]. Proof that decades-matured native AOT can
  stand in for a JIT — a seat cljw's equivalents of which are the Wasm
  routes (zwasm JIT / ClojureWit WasmGC) [INFERRED].

#### Win-per-complexity ranking (R1b's synthesis, evidence-based)

Premise [INFERRED]: under F-012 (VM = production, tree_walk = oracle),
**tiers added inside the VM backend do not break behavioral equivalence** —
the oracle checks semantic equality, and specialization→deopt preserves
semantics by construction.

| #  | Technique                                                      | Proven gain                                                                                                                        | cljw complexity/budget cost                                                                                          | Verdict                                         |
|----|----------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|-------------------------------------------------|
| 1  | **Adaptive specialization + quickening (PEP 659 model)**       | +25% avg whole-interpreter; call-family +20% [MEASURED-cited]                                                                      | Medium. No machine code, ISA-independent, ~size-neutral, deopt = rewrite back; closed inside the VM                  | **Prime**                                       |
| 2  | **Call/frame structural reform (lazy frames + call inlining)** | CPython 3–7% + 1–3%, recursion 1.7× [MEASURED-cited]; also the core of LuaJIT's speed                                           | Medium-large (same direction as ADR-0184 Alt 3 template/closure split). bindCallFrame 16% is the direct target       | **Prime (already the named finished form)**     |
| 3  | **Interpreter-internal IC (protocol/Var/keyword call sites)**  | Deegen +28% over LuaJIT interp incl. IC [MEASURED-cited]; Serrano & Feeley up to ~4× on cache-miss-heavy benches [MEASURED-cited] | Small-medium: bytecode cache slots only. Over-polishing proven wasteful (arXiv 2502.20547) — stop at the basic form | **Prime**                                       |
| 4  | **Superinstructions / fusion**                                 | Sparse modern isolated measurements; same root as specialization (dispatch-count reduction)                                        | Small; gain bounded by a slice of the ~23% dispatch bucket                                                           | Worth doing (small ball)                        |
| 5  | **Tail-call / computed-goto dispatch swap**                    | 3–5% geomean corrected, ±0% possible by compiler [MEASURED-cited]                                                                | Small; Zig musttail-equivalent portability risk                                                                      | Low expectation (measure once, close)           |
| 6  | **Sparkplug-type baseline JIT (no IR, template)**              | +5–15% measured — on an IC-complete system; more for IC-less [MEASURED-cited]                                                    | Large: even ARM64-only needs codegen+OSR+debugging. ADR-0151 substrate exists; broad-JIT is user-fenced              | Future slot (decide zwasm JIT role split first) |
| 7  | **Copy-and-patch JIT**                                         | Raw power: +39–63% over Liftoff-class code [MEASURED-cited]; in CPython ±0→4–12%                                               | Large: Zig has no build-time stencil extraction (LLVM/ghccc) equivalent; stencils hit the 7 MB budget directly       | Unfavorable for cljw                            |
| 8  | **LBBV (YJIT model)**                                          | railsbench +38%, production 5–10% [MEASURED-cited]                                                                                | Very large: took Shopify years; and the owners are migrating to method-SSA (ZJIT)                                    | Not recommended solo                            |
| 9  | **Tracing JIT**                                                | Documented degradation on branchy code; trace explosion [CLAIMED anecdote]                                                         | —                                                                                                                   | **Excluded for a BFS-heavy profile**            |
| 10 | **Truffle partial evaluation**                                 | 0.83× V8 [MEASURED-cited]                                                                                                         | Foundation too large                                                                                                 | Excluded                                        |

Three-line conclusion (R1b): (1) the measured record says **+25–50% is
available inside the interpreter before any JIT**, and cljw's ~45%
dispatch+call profile is that take's exact shape; (2) the first move is the
triple (a) adaptive specialization + (b) call/frame structure (ADR-0184
Alt 3 direction) + (c) call-site IC — all VM-internal, ISA-independent,
size-neutral, F-012-compatible; (3) if a machine-code tier ever lands, a
Sparkplug-type baseline is the proven best complexity-for-effect — after
the zwasm JIT role split (gap II × III) is decided; tracing and
copy-and-patch are disfavored by measured evidence under cljw's constraints.

---

## 5. The Clojure tax — what the semantics cost, and how the family pays

R1d read JVM Clojure (local `~/Documents/OSS/clojure`, 1.13.0-master-
SNAPSHOT), SCI/babashka (SCI HEAD e4ab8e9 with its ADR 0001–0018 measured
data; babashka HEAD be81e9c), ClojureScript, jank, and ClojureDart. Paths
below under `src/jvm/clojure/lang/` are abbreviated to ClassName.java.

### 5.1 How JVM Clojure is fast (source-verified)

- **Every `fn` is a dedicated final JVM class** generated with ASM
  (Compiler.java L4483 FnExpr / L4886 `ACC_FINAL` — final helps C2
  devirtualize); closures are instance fields; **literals/keywords/Vars are
  `static final const__N` fields** initialized in `<clinit>` (L5176-5237) —
  runtime keyword use is one GETSTATIC, zero allocation.
- `(f x)` with f a Var emits `GETSTATIC const__N` → `INVOKEVIRTUAL
  Var.getRawRoot()` → `CHECKCAST IFn` → args → `INVOKEINTERFACE IFn.invoke`
  (InvokeExpr.emit L4232, emitVarValue L5760). `getRawRoot()` is **one
  volatile field read** (Var.java L87/L261). Only `^:dynamic` pays
  `Var.get()` = AtomicBoolean `threadBound` check + (when bound) ThreadLocal
  + hash-map lookup (Var.java L194-198/L359). **Var indirection is
  compressed to one volatile load in the non-dynamic case.**
- **Direct linking** (`-Dclojure.compiler.direct-linking=true`): non-dynamic
  non-`^:redef` Var calls become `StaticInvokeExpr` →
  **`INVOKESTATIC <fnClass>.invokeStatic(...)`** (Compiler.java L4354-4374)
  — Var deref, IFn cast, and invokeinterface all vanish. `invokeStatic` is
  generated for `canBeDirect` fns (L4631); **clojure.core itself is built
  direct-linked** (build.xml L57/111/127/144).
- **No runtime arity dispatch**: IFn has 22 fixed invoke arities
  (IFn.java L25-93; `MAX_POSITIONAL_ARITY = 20`, Compiler.java L145);
  selection happens at compile time.
- **Primitive specialization**: 358 nested `IFn$LL`-style interfaces
  (arity 0–4 × L/D/O each position); **long and double only**
  (Compiler.java L5881-5894), ≤4 args (L5896-5908). Callers with prim
  `:arglists` metadata get rewritten to `.invokePrim` (L4376-4394), erasing
  boundary boxing. loop/recur primitives live in real JVM slots
  (LLOAD/DLOAD); type-mismatched recur re-parses the loop boxed with an
  "Auto-boxing loop arg" warning (L6971-6980) — the main door through which
  boxing sneaks into hot loops.
- **Persistent structure engineering** (the part that dominates
  collection-heavy workloads):
  - PersistentVector: 32-way trie (5-bit) + **tail array** (`tailoff()`
    L146-150; conj on the last ≤32 elements copies only the flat tail).
    TransientVector (L670-960): `edit` = `AtomicReference<Thread>` identity
    comparison for in-place mutation of owned nodes — and **the thread check
    is effectively disabled** (only use-after-`persistent!` is checked, L698;
    the owner-thread comparison is commented out, L711-716): speed was
    chosen.
  - PersistentHashMap (HAMT): exactly 3 node classes — ArrayNode (L403),
    BitmapIndexedNode (L675), HashCollisionNode (L930); sparse→dense index
    via `Integer.bitCount(bitmap & (bit-1))` = **one POPCNT** (L682);
    Bitmap→Array promotion at 16 entries (L713-731), pack-back at ≤8.
  - PersistentArrayMap: linear array up to **8 entries** — but **64 entries
    when all keys are keywords** (L35-36, L262-283): interned keywords
    compare with `==`, so linear scan wins. `Util.EquivPred` is hoisted out
    of the loop to make type dispatch once-per-collection.
- **Chunked seqs**: chunk size 32; only 4 IChunkedSeq implementations;
  PersistentVector's leaf arrays are reused as chunks directly (L479);
  `LongRange`'s chunk is **virtual — no array at all** (`start + i*step`,
  LongRange.java L210-258). Producers/consumers: 1-coll map, filter, concat,
  doseq, for, map-indexed, keep (core.clj L2760-2768, L2824-2833).
- **reduce fast path**: `clojure.core/reduce` (core.clj L7016-7036) is one
  `instanceof IReduce/IReduceInit` + invokeinterface into the collection's
  internal reduce — not even the protocol machinery. PersistentVector.reduce
  walks leaf arrays directly (L413-425); LongRange.reduce runs a **primitive
  long counter**, boxing only at f-call (L152-176). `into` = `(persistent!
  (reduce conj! (transient to) from))` (L7098-7118) — zero intermediate
  persistent structures, zero intermediate seqs.
- **Protocols — a 3-layer inline cache handing off to the JVM's PIC**:
  (a) per-call-site static Class field + `IF_ACMPEQ` against the previous
  class; direct implementers take `INSTANCEOF → CHECKCAST →
  INVOKEINTERFACE` with no Var deref (InvokeExpr.emitProto,
  Compiler.java L4249-4293) — mono/polymorphic optimization beyond that is
  **C2's job at the invokeinterface site**; Clojure's job ends at "make the
  site look monomorphic". (b) MethodImplCache: 1-entry MRU + a **perfect
  hash table over class identity hashes** (shift/mask/array load/reference
  compare; built by core_deftype.clj L523-538). (c) The generated protocol
  fn holds `__methodImplCache`; `extend` swaps the whole cache
  (redefinability preserved).
- **Keyword lookup sites**: `(:foo x)` compiles to a per-site static
  `ILookupThunk` (KeywordLookupSite.java, Compiler.java L3800-3877);
  defrecords implement `IKeywordLookup` so the thunk collapses to class
  identity check + **direct getfield** (core_deftype.clj L205-225).
- **Compiler intrinsics**: `Numbers.add(double,double)` → `DADD`;
  `Numbers.lt(long,long)` → `LCMP; IFGE` (predicates branch directly, no
  Boolean allocated, Compiler.java L3262-3265); `case*` → perfect
  shift/mask `tableswitch` (CaseExpr, L9352-9500); locals clearing writes
  `ACONST_NULL` after last use (L5700-5726) — the mechanism that lets
  infinite lazy seqs be consumed without head retention.

### 5.2 Decomposing "JVM C2's share" vs "Clojure's own design's share"

No isolation experiment exists, but the family provides a pincer [INFERRED,
with SCI-ADR and jank numbers as MEASURED-cited inputs]:

- **Same JVM, Clojure-design removed = SCI on JVM**: interpreting
  `sum-loop 1e7` takes 50.7 ms vs 2.39 ms compiled = **~21×** (SCI ADR
  0018); fib 27: 9.36 vs 1.46 = ~6.4× [MEASURED-cited]. C2 applies equally
  to both — so the 21× is owned by Clojure's translation into static
  bytecode structure (real JVM locals, fixed arity, intrinsics).
- **Same Clojure semantics, C2 removed = native-image (bb)**: dispatch
  overhead grows HotSpot ~22% → native ~34% (SCI ADR 0006); the 1e7 loop is
  190 ms native vs ~3 ms JVM C2 = **~60×** (ADR 0016) [MEASURED-cited].
- **LLVM in place of C2 = jank**: LLVM IR without Clojure-aware optimization
  runs fib 35 at 5,522 ms vs JVM ~200 ms (**27× slower**); a Clojure-
  specific IR doing inlining + box/unbox removal + tagging reaches 114 ms
  (**beats the JVM**) [CLAIMED, jank blog 2026-05-08].
- Conclusion [INFERRED]: in numeric/call-heavy code, speed comes from
  *compiling with semantics-aware optimization*; C2 contributes the generic
  layer (inlining, escape analysis, devirtualizing monomorphic
  invokeinterface) for free, and Clojure's design *is* the act of
  translating semantics into C2-edible shapes. But in **collection-heavy
  real workloads (rush-hour BFS class) the shares invert**: the §5.1 data-
  structure engineering (tail/POPCNT/transients/chunks/internal-reduce)
  dominates — which is why bb holds at 2.3× vs the JVM [MEASURED-here]:
  its stdlib runs as compiled, direct-linked code.

### 5.3 SCI / babashka — "analyze once + closure tree", and its measured walls

- Execution model: parse → analyze → eval-node tree. The compile unit is the
  `->Node` macro (sci/impl/types.cljc ~L232-262): on the JVM each node kind
  is a `reify Eval` class — **no op-keyword case dispatch exists at
  runtime**; dispatch is burned into which node type was constructed
  (~90 construction sites in analyzer.cljc, 2358 lines). Locals are
  integer-slot `Object[]` (aget by index). Each sci fn call allocates an
  `object-array` + per-param `aset` + enclosed-array copy + interrupt check
  + recur-sentinel trampoline (fns.cljc `gen-fn`, arities 0–20 + varargs).
- **Why loops are slow — SCI's own ADR measurements** [MEASURED-cited]:
  `(loop [i 0 j 1e7] …)` originally did **8 protocol dispatches per
  iteration**; HotSpot monomorphizes to ~22% overhead but **native-image
  has no JIT so every dispatch is a real vtable lookup (~34%)** (ADR 0006).
  Fused binding nodes + analysis-time static-method specialization
  (`inc` → `Numbers/inc`) took native bb from 338 → 191 ms (**−43%**).
  All values are boxed — a 1e7 loop allocates 1e7 Longs; primitive
  specialization is acknowledged as "the remaining ~95% of the gap" but
  rejected: a prototype `long[]` register VM (native ~204→~88 ms) hit
  **0 applicable sites across bb's 5,555 library tests** — a load-bearing
  negative result: **under dynamic dispatch, primitive specialization does
  not fire** [MEASURED-cited]. ADR 0016: native bb 1e7 loop 190 ms vs JVM
  C2 ~3 ms (~60×); ADR 0006: bb's 191 ms is **2.7× faster than Python 3.13
  (520 ms)** on the same loop — interpretation still beats CPython. Load
  side: 8 libraries load in ~52 ms (analysis 38%); the analyzed AST cannot
  be cached across processes because nodes are closures/reify (ADR 0010).
- **babashka = compiled stdlib + interpreted user code**: the uberjar is
  AOT'd with direct linking; the interpreter and the stdlib (clojure.core,
  cheshire, babashka.fs, core.async, …) are burned into the native image as
  compiled JVM Clojure; only user forms become node trees. GraalVM
  native-image's closed world (`--no-fallback`; no `defineClass`) is **why
  bb interprets at all** ("runtime class definition is forbidden" — ADR
  0016). Startup ~10 ms [MEASURED-cited]. The interop allow-list
  (impl/classes.clj, 1,212 lines) doubles as the native-image
  reflect-config — allow-list and closed world are the same data.
- Implication [INFERRED]: bb holds 2.3× on rush-hour because **BFS time is
  mostly spent inside compiled, direct-linked clojure.core (persistent
  structures, seq machinery, hash/equality); the interpretation tax only
  touches the thin user-fn skin**. cljw's 5×-vs-bb residual is therefore
  not interpretation tax but (a) core itself running on VM dispatch plus
  (b) the maturity gap in §5.1-class data-structure/reduce/chunk
  engineering [INFERRED].

### 5.4 ClojureScript — translate semantics into the host JIT's favorite shapes

- **Var indirection does not exist in the common case**: `:var`/`:binding`/
  `:js-var`/`:local` all emit a munged JS name (compiler.cljc L455-503); no
  runtime Var object, no deref. **`binding` literally expands to
  `with-redefs`** (core.cljc L2331-2342) — single-threaded, so save/set!/
  finally-restore suffices. `^:dynamic`'s codegen meaning is only "excluded
  from static-fns direct linking" (compiler.cljc L1203-1205).
- **Arity dispatch is erased statically**: known-arity calls emit
  `f.cljs$core$IFn$_invoke$arity$N(...)` directly (compiler.cljc
  L1200-1290); `:static-fns` is **forced on under `:advanced`**
  (closure.clj L3024-3025).
- **Protocols → bitmask + property access, PICs delegated to V8**:
  deftype/defrecord constructors bake per-partition
  `cljs$lang$protocol_mask$partitionN$` masks (compiler.cljc L1478/L1495);
  statically-known implementers get the protocol method emitted as a
  **direct property call** (L1284-1290). cljs builds no PIC of its own — it
  translates dispatch into fixed-hidden-class property access that V8's IC
  monomorphizes [INFERRED] — the same design judgment as the JVM version
  handing invokeinterface to C2.
- **Persistent structures are the same design, so the tax stays**: same
  tail-array vector (core.cljs L5605/L5776), same 3-node HAMT (L7412/
  L7649/L7759), array-map threshold 8 (L7100), same chunking (L3698-3977).
  JS-specific extra tax: Murmur3 via `Math/imul` (L953-975) and a
  **string-hash cache object** (L1023-1040) — needed because JS strings,
  unlike Java's, don't cache their hash. `:advanced` shrinks code, not work:
  Closure's DCE/renaming never touches trie walks or node copies.
- **Numbers: zero boxing tax, int64 lost**: `(+ a b)` is the raw JS `+` via
  `js*` templates (core.cljc L1089, L928-994); V8 keeps Smi/doubles unboxed
  [INFERRED]. The price is int64/ratio/bignum.
- **squint / cherry — the "sell persistence" endpoint**: squint compiles
  ClojureScript *syntax* to JS with **only built-in JS data structures**
  (mutable objects/arrays; keywords = strings; `assoc` = shallow copy — no
  structural sharing, so CoW can be *slower* on big data; seqs mostly
  eager); runtime ~10 KB [unverified]; aimed at "CloudFlare workers / node
  scripts / GitHub actions… that need the extra performance, startup time
  and/or small bundle size" [CLAIMED, README 2026-08-06] — with borkdude's
  own caveat that gains are "very contextual" [CLAIMED, borkdude blog
  "porting-cljs-project-to-squint"]. cherry keeps CLJS persistent
  structures at ~300 KB minimum bundle (56 KB gzipped) [CLAIMED, borkdude
  DCD 2022 deck]. The same author
  (borkdude) thus implements both poles: SCI/bb (keep dynamism, pay speed)
  and squint (sell semantics, take JS-native speed).

### 5.5 jank — the closest prior art for "native Clojure + JIT"

- Architecture: C++ Clojure dialect; Clojure source → own analysis → LLVM IR
  → LLVM ORC JIT; REPL/eval via Clang-based C++ JIT (CppInterOp). Object
  model: closed `enum class object_type : u8` + non-virtual type-erased
  objects, switch-based dispatch (object.hpp, visit.hpp — the virtual-
  function model was abandoned in 2023); the enum includes
  `small_integer`/`small_real`, reflecting 2026 pointer-tagging/NaN-boxing.
  GC: **Boehm (bdwgc)** — conservative, non-moving. Persistent structures:
  **immer** (RRB/CHAMP) instantiated with a GC memory policy — jank did not
  write its own. Function objects split by type: jit_function / jit_closure
  / jit_variadic_function; chunked seqs implemented.
- Published trajectory [CLAIMED, jank blog, dated]:
  - 2023-08-26 (object model rewrite): raytrace **jank 36.96 ms vs Clojure
    JVM 69.44 ms** (~1.9× faster); map lookup 2× improved.
  - 2024-11-29: moved from C++ codegen to direct LLVM IR.
  - 2026-05-08 ("jank now has its own custom IR"): LLVM IR is too
    low-level — it "has no concept of Clojure's vars / transients /
    persistent structures / lazy seqs", leaving LLVM almost no optimization
    room. With a Clojure-specific SSA/CFG IR: **fib 35: 5,522 ms initial →
    2,309 (inlining) → 1,400 (nil opts) → 282 (63-bit pointer tagging) →
    114 ms (aggressive inlining)** vs JVM ~200 ms — ending ~43% faster than
    the JVM.
  - 2026-06-01 (raytrace): **Clojure 1.12.4/OpenJDK 21: 2.53 s; jank 8.10 s
    initial (3.2× slower) → 4.16 (NaN boxing for floats) → 3.02
    (dynamic_call removal — direct virtual dispatch for fixed-arity fns) →
    2.37 s (keyword map-lookup inlining)** — ~6% faster than the JVM. Plus
    two passes — literal dedup/hoisting and var-deref hoisting — together
    shrinking generated clojure.core code by >30%.
  - Maturity: alpha since 2026-01; nREPL works; packaging blocked on LLVM
    23; an LLVM 22 regression took startup **1 s → 76 s** before a codegen
    redesign recovered it — the LLVM-dependency startup risk, recorded.
- Reading [INFERRED]: jank's 2026 posts are the demonstration that **even
  with AOT/JIT, going straight to a semantics-blind low-level IR loses to
  the JVM**; the winning levers — Clojure-specific IR inlining + box/unbox
  removal, numeric tagging (63-bit int + float NaN-box ≒ cljw's F-004
  family), var-deref hoisting, fixed-arity direct calls (dynamic_call
  removal) — hit exactly cljw's profile buckets (dispatch ~23% + call
  machinery ~22.5%). The biggest steps in fib's 48× journey were pointer
  tagging (5×) and inlining (2.4× + 2.5×) — "structural levers ≫ constant
  factors", the same lesson as R0.

### 5.6 ClojureDart — the AOT, eval-free endpoint

- Clojure → Dart source AOT transpilation; no runtime eval/compiler, no
  REPL (hot reload instead); macros expanded on the JVM until self-hosted;
  no multimethods (protocols instead) [CLAIMED, differences.md,
  2026-08-06].
- "defs are not initialized in order but lazily on a by-need basis. This is
  a consequence of Dart tree-shaking and fast startup goals" [CLAIMED] —
  top-level def initialization order is *sold* so Dart AOT tree-shaking can
  drop unused vars. Dart-native int/double (no bignum).
- Position [INFERRED]: sell all dynamism, buy all of Dart AOT's native code
  quality + tree-shaking — viable because Flutter's domain (startup and
  size paramount, eval unnecessary) permits it. The exact opposite corner
  from cljw's commitments.

### 5.7 The semantic-tax ledger T1–T7

| Tax                                                                        | What it costs                       | Who pays / how they dodge                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|----------------------------------------------------------------------------|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **T1 Persistent-by-default collections** (trie walk + path copy + hashing) | Per-op node allocation and copying  | Everyone but squint pays; the dodge is engineering, not abandonment: JVM tail array / POPCNT bitmap / ≤8-entry array-maps (64 for keyword keys) / transients with the thread check disabled / `into` via transient. CLJS reimplements the same. SCI/bb inherit the host's compiled classes. jank delegates to immer. **squint alone abandons** (JS objects + shallow copy) and picks up a counter-tax (no structural sharing).                                                                                                                                                                               |
| **T2 Seq abstraction** (a cell per iteration step)                         | Allocation per step                 | JVM: chunk-32 (LongRange chunks are array-free), IReduce internal iteration (zero seq cells), locals clearing. CLJS same. SCI imports host chunking (its own `for` is unchunked — completeness is hard). squint goes eager. jank has chunked_cons + IR scope.                                                                                                                                                                                                                                                                                                                                                |
| **T3 Var indirection** (the price of redefinability)                       | A load per reference                | JVM: one volatile load; direct linking deletes it (opt-out `^:redef`/`^:dynamic`); only `^:dynamic` pays ThreadLocal. CLJS: erased to static names at compile time; binding = with-redefs. ClojureDart: lazy static init + tree-shaking, no runtime redef. SCI: volatile-mutable field + thread-bound check per deref. jank: literal + var-deref hoisting passes (−30% core codegen). **Proven landing zone: deref ≤ 1 volatile load, plus a hoist/direct-link escape hatch.**                                                                                                                               |
| **T4 Dynamic arity dispatch**                                              | Per-call selection + arg packing    | JVM: nonexistent — 22 fixed IFn arities selected at compile time; prim hints erase boxing too. CLJS: `…$arity$N` direct property calls (forced under `:advanced`). SCI: per-arity host fns but per-call `object-array` + aset remains. jank: deleted central `dynamic_call` → −27% on raytrace. **cljw's bindCallFrame 16% + call 6.5% is exactly this tax; the family's unanimous answer: fix arity selection and argument transfer into compile-time shape.**                                                                                                                                            |
| **T5 Value equality across types** (`=`)                                   | O(n) walks + type dispatch          | JVM: `Util.equiv` ladder + intrinsic `LCMP` for primitives + `EquivPred` hoist; keywords are `==`. CLJS: fqn `===` for keywords, `-equiv` protocol, own string-hash cache. squint keeps deep-compare but loses sharing shortcuts. **The tax is essentially O(n); the only escapes are hash-first comparison and identity fast paths** [INFERRED].                                                                                                                                                                                                                                                             |
| **T6 Boxed numbers by default**                                            | Allocation per arithmetic op        | JVM: pays by default (`Numbers.ops` getClass chain), with the most systematized escape hatches (prim hints, real prim loop slots, intrinsics, `*unchecked-math*`, `:warn-on-boxed`) — and still relies on C2 escape analysis for the rest. SCI: all boxed; prim specialization rejected on a measured 0-hit rate. CLJS: free (JS numbers), price = int64/ratio/bignum. jank: 63-bit tagging (fib's single biggest lever) + float NaN-box. ClojureDart: Dart natives. **cljw: F-004 NaN-box already sits on jank's side — this tax is already dodged and is not the residual gap's main driver** [INFERRED]. |
| **T7 Laziness + dynamism itself** (eval / runtime redefinition)            | Cell allocation + closed-world loss | The trade that shapes each system: bb keeps eval by interpreting (20–60× on loops, 2–3× real workloads via the compiled-stdlib two-layer trick); ClojureDart sells eval for Dart AOT; CLJS pays by mode; jank keeps eval via LLVM JIT at toolchain-weight cost (1 s → 76 s incident); **cljw's own VM + own JIT is the middle point: keep eval without LLVM-class weight** [INFERRED].                                                                                                                                                                                                                   |

### 5.8 Placing cljw's 11.5× in family coordinates

- rush-hour coordinates [MEASURED-here]: clj 1.07 s / bb 2.46 s / cljw
  12.3 s.
- bb's position proves: **even interpreted, a real workload stays in the
  2–3× band if the collection engineering is compiled best-in-class**. The
  cljw-vs-bb 5× residual is (a) core running on VM dispatch + (b) the
  §5.1-class data-structure/reduce/chunk engineering maturity gap
  [INFERRED].
- jank's position proves: **AOT/JIT alone does not win; semantics-aware
  optimization (inlining, box removal, tagging, var hoisting, arity direct
  calls) at the IR level is what reaches the JVM** [CLAIMED numbers,
  INFERRED reading].
- The family's prescriptions for cljw's residual (dispatch ~23% + call
  ~22.5%) are all precedented: fusion/superinstructions (SCI fused nodes),
  static call-frame shaping (JVM fixed arity / jank dynamic_call removal),
  thorough internal-reduce + chunking (JVM §5.1) [INFERRED].

---

## 6. The Wasm substrate

### 6.1 zwasm today (local primary sources, read 2026-08-06)

- **zwasm v2 is "feature-complete and green on the 3-host gate"** (Mac
  aarch64 + Linux x86_64 + Windows x86_64); Wasm 1.0/2.0/3.0 spec testsuite
  100% (3.0 = all 9 proposals: GC / EH / tail-call / memory64 /
  multi-memory / typed funcrefs / extended-const / relaxed-simd /
  annotations). WASI p1 ✅ / p2 (Component Model) ✅ default-ON / p3 🚧
  core opt-in. Execution: interp + JIT (arm64 AAPCS64 / x86_64 SysV /
  x86_64 Win64) + AOT (`.cwasm`), all with WASI I/O. SIMD-128 executes on
  JIT only (design decision) [zwasm README]. GC-on-JIT is a conservative
  native-stack-scan collector, memory-safe (use-after-free attack-tested on
  both arches) [zwasm README] — **zwasm is a spec-complete WasmGC host**,
  a fact that matters for §8.
- Latest tag **v2.4.1 (2026-08-04)**: a consumer-driven patch fixing two
  ClojureWasm findings — the multi-export component validation bug (cljw
  D-567 / zwasm D-527) and a capture-buffer cap. **cljw's pin is v2.4.0
  (2026-08-03), so a user-gated pin bump alone resolves D-567**
  [MEASURED-cited, zwasm CHANGELOG/tag].
- **zwasm ADR-0200 (JIT-backed embedding API)**: ACCEPTED, compute path DELIVERED
  2026-06-21. Enum knob `EngineKind{auto,jit,interp}`, per-instance
  selection, interp+JIT coexist in one binary (cljw's dual-engine diff-
  oracle requirement), `auto` = JIT where a backend exists, explicit `jit`
  errors on JIT-less arches (no silent downgrade). cljw adopted `.auto` as
  default (D-488, discharged 2026-06-22); cljw's own measurement:
  **JIT ≈ 44× interp on a 1e8 loop** (`bench/wasm_jit_vs_interp.sh`)
  [MEASURED-here, ledger 2026-06-21]. **Remaining north-star gap:
  components-through-the-JIT** — components are interp-pinned in zwasm
  (zwasm D-500, Win64 string-arg wrapper-thunk gap).
- **zwasm's own comparative bench** (docs/benchmarks.md, M4 Pro, hyperfine,
  sustained compute, mean ms) [MEASURED-cited]:

| Fixture  | zwasm-jit | zwasm-aot | wasmtime | wazero | wasmer | zwasm-interp |
|----------|----------:|----------:|---------:|-------:|-------:|-------------:|
| fib2     |      1077 |      1083 |      700 |    781 |    713 |        39747 |
| sieve    |       320 |       318 |      203 |    490 |    206 |        13601 |
| matrix   |       343 |       342 |       88 |    198 |     93 |         5399 |
| heapsort |      1574 |      1573 |      642 |    926 |    647 |        15666 |
| base64   |       781 |       780 |       57 |     79 |     62 |         7028 |

  Optimizing JITs (Cranelift-class) beat zwasm-jit by **1.5–3.9×** (base64
  **13.7×** — vectorizable 6-bit grouping is the single-pass structural
  worst case); zwasm-jit ≈ zwasm-aot (shared codegen). Startup-bound short
  workloads: zwasm-aot **2.0–2.3 ms** end-to-end vs wasmtime 6.3–7.2 ms /
  wasmer ~12 ms / WasmEdge ~16.5 ms — zwasm fastest. Peak RSS zwasm
  2.1–5.1 MB (4–12× under the field). Self-reported JIT ≈ 10–40× interp.
  **This table is an anchor: borrowing zwasm as a codegen substrate puts
  the ceiling at "Cranelift minus 1.5–3.9×"** [MEASURED-cited].

### 6.2 Wasmtime's tier map — the industry baseline trade

- **Cranelift** (optimizing: regalloc2 + e-graph mid-end), **Winch**
  (baseline: canned per-opcode machine code, single pass, x86_64/AArch64),
  **Pulley** (portable interpreter, late 2024 —, whose maintainers say it
  is "by no means outstripping other wasm interpreters" [CLAIMED, issue
  #10102]).
- The quantitative anchor [MEASURED-cited, Wasmtime baseline-compilation
  RFC, Sightglass]: **baseline compiles 15–20× faster than optimizing and
  produces code 1.1–1.5× slower**. The TPDE paper (arXiv 2505.22610) has
  Winch compiling 1.74× faster than TPDE (≈ ~7×+ faster than Cranelift)
  [MEASURED-cited]. zwasm's wider 1.5–3.9× gap vs the RFC's 1.1–1.5× is
  consistent with being simpler than Winch (no regalloc/peephole)
  [INFERRED].
- Calls and instantiation [MEASURED-cited, vendor]: wasmtime guest→host
  call **~10 ns** (BA 2023 article); wasm function-call overhead a few ns
  and instantiation µs-class (~5 µs) via CoW memory images (BA "wasmtime
  1.0: performance", 2022); Fastly's **35.4 µs** cold start [CLAIMED,
  launch press release].
- Implication: even wasmtime split into compile-latency vs throughput
  tiers. The same split maps onto cljw's own VM (interp → baseline JIT →
  someday optimizing) — cljw today is interp-only with an
  execution-verified ARM64 substrate whose micro-lever was rejected at
  3–4.5% [MEASURED-here, D-386].

### 6.3 WasmGC — ship status and honest overhead

- Hosts: all major browsers (Chrome 119 / Firefox 120 / Edge 119, 2023-11;
  Safari 18.2, late 2024); **Wasm 3.0 (incl. GC) became a W3C standard
  2025-09**. wasmtime 27.0 (2024-11)
  "Complete Wasm GC support", default-on since; collector selectable null /
  DRC / **copying (current default, v46)** — with the project itself saying
  performance work is still ahead ("correctness first") [CLAIMED, Bytecode
  Alliance]. zwasm: Wasm 3.0 GC 100%, GC-on-JIT conservative stack-scan
  [zwasm README].
- Measured/claimed overhead of GC languages compiled to WasmGC, vs their
  native VMs:

| Language/system                 | Baseline     | Number                                                                     | Grade                                                   |
|---------------------------------|--------------|----------------------------------------------------------------------------|---------------------------------------------------------|
| OCaml (wasm_of_ocaml)           | native OCaml | **~2× slower**                                                            | [CLAIMED-strong, Tarides 2025-02, micro+macro]          |
| OCaml (wasm_of_ocaml)           | js_of_ocaml  | 2–8× faster (Jane Street prod)                                           | [CLAIMED]                                               |
| Scheme (Hoot → wastrel AOT)    | Guile native | 4.44 s vs ~3.5 s = **~1.27× slower**                                      | [MEASURED-cited, wingolog 2026-04-09]                   |
| Scheme (Hoot on Chrome/Firefox) | wastrel      | **5–6× slower**                                                          | [MEASURED-cited] — browser WasmGC tiers still immature |
| Kotlin/Wasm                     | JVM          | "approaching JVM on Chrome"                                                | [CLAIMED, JetBrains 2025, no multiplier]                |
| Kotlin/Wasm (Compose Web)       | Kotlin/JS    | ~3× faster (UI-heavy)                                                     | [CLAIMED]                                               |
| Dart/Flutter web                | JS build     | 2–3× faster; startup −40–50%                                            | [CLAIMED; renderer differences mixed in]                |
| Common caveat                   | —           | WasmGC allocation slower than linear-memory allocation (alloc-heavy loops) | [CLAIMED, multiple sources agree]                       |

  Reading: **"1.3–2× vs the native VM" is the honest 2026 band**; vs JS it
  nearly always wins (hence the vendor marketing axis); variance across
  engines is large, and wasmtime's GC lags browsers [INFERRED from the
  wingolog 5–6× spread].
- Cross-check against ClojureWit S0 [MEASURED-cited, doc/design/0010,
  2026-07-29]: on wasmtime, generic dispatch costs **~6.1 ns over a direct
  call** (6× the 1 ns budget); on V8 it is 0.13 ns and passes untouched;
  guard-specialized sites pass on both (≤0.15 ns). Boxed arithmetic costs
  **0.31× JVM Clojure (≈3× faster); the unboxed floor is 2.1× slower** —
  the same shape as the band above. The WasmGC route's speed hinges on
  borrowing V8/wasmtime's optimizing tier plus static guard specialization;
  the compiler-side guard *coverage* is the true unknown (S3 residue). §8
  details.

### 6.4 Component Model / WIT — boundary costs and timeline

- Canonical ABI: cross-component and host↔component values are
  **lift/lower = copies**; string/list/record marshal through linear memory
  with realloc + copy required by spec (shared-nothing is the design
  principle; **no shared GC references across a component boundary**)
  [primary, CanonicalABI.md]. Therefore hot paths must never sit on a
  component boundary; the seam belongs at coarse-grained APIs
  (request/batch units) [INFERRED; ClojureWit doc 0007 reaches the same
  conclusion]. Call cost itself: ns–10 ns class on wasmtime (§6.2);
  ClojureWit 0013 has the detailed decomposition (§8.3).
- zwasm component-instantiate cost: **unmeasured** [GAP — one hyperfine
  data point on a p2 fixture would close it].
- Timeline: WASI 0.2 (p2) current-stable; zwasm's wasmtime-equivalence
  campaign done 2026-06-13 (official corpus 158/0/0) [zwasm README]. WASI
  **0.3.0 released 2026-06-11** (native async: `async func` / `stream<T>` /
  `future<T>`; wasi:io absorbed into the ABI); wasmtime 43+ and jco
  support it; zwasm core opt-in. **WASI 1.0 targeted late 2026 / early
  2027** [wasi.dev roadmap].

### 6.5 Cold start / snapshots — the axis Wasm structurally wins

- Wizer: pre-executed initialization snapshotted into a new module —
  **1.35–6.00×** faster instantiation+initialization [MEASURED-cited,
  vendor README]; adopted by Fermyon Spin. Cloudflare Python Workers
  (2025-12): fastapi+pydantic load **~10 s → ~1 s** via memory snapshots
  [CLAIMED]. Fastly: **~35.4 µs** [CLAIMED]. zwasm: AOT `.cwasm`
  full-process **2.0 ms** + on-disk compile cache (`--cache`, v2.2.0) —
  cljw has this surface "NOT adopted, evaluation pending" in the capability
  ledger.
- cljw itself already holds this axis natively (startup cache D-140 + AOT
  envelope); what the Wasm substrate adds is **guest-code** cold start
  [INFERRED]. But a future "AOT Clojure code to `.cwasm` and distribute"
  shape would inherit zwasm's 2 ms start and Wizer-style heap-inclusive
  pre-initialization (a frozen clojure.core-loaded state) — a property JVM
  Clojure structurally cannot have [INFERRED].

### 6.6 Can you JIT *inside* Wasm? No — with three escapes

- Wasm is a Harvard architecture: code is not addressable, functions are
  called by immediate index, and a module has no way to write new code into
  itself [primary, wingolog 2022-08-18].
- Escapes: (1) **host-side tiering** (the standard answer; zwasm's JIT is
  this); (2) **late linking** (wingo/wasm-jit; Flycast dynarec): the guest
  generates new wasm module bytes at runtime and asks the host to
  instantiate them; the new module imports main memory + the indirect
  function table and patches itself in — host cooperation required; the
  jit-interface Explainer motivates the approach with "10 to 100 times"
  over interpretation [CLAIMED, Explainer]; Flycast's dynarec went from a
  2 FPS interpreter to a locked 60 FPS [CLAIMED, Flycast]; wingo's fib:
  wasmtime 0.232 s/inv vs SpiderMonkey 0.392 / V8 0.729 [MEASURED-cited,
  blog]; the WebAssembly/jit-interface proposal exists but appears stalled
  [unverified]; (3)
  **pre-deploy AOT / partial evaluation** (Wizer, wasm-opt) — dynamism
  abandoned.
- Consequence [INFERRED]: a compiled-to-Wasm Clojure that wants eval must
  either bundle an interpreter in the module (Hoot's choice; size) or
  depend on host late-linking (portability loss). ClojureWit's dev/prod
  two-mode design (doc 0009) is the head-on answer. Conversely, **cljw as a
  native runtime does not carry this constraint at all** — it can keep
  eval/REPL/var-rebinding while lowering only static parts to wasm/JIT.
  This is the native-runtime route's essential advantage.

### 6.7 What would zwasm-JIT fusion actually buy cljw?

Premise [MEASURED-here]: rush-hour 12.3 s, interpreter structural cost
(dispatch ~23% + bind ~16% + call ~6.5% + TLV ~8%) is the majority; GC only
3.8%. Any fix for 11.5× must attack dispatch/call — i.e., some codegen.

- **Option A1 — compile Clojure to wasm modules, let zwasm-JIT run them.**
  Buys the whole codegen estate (arm64/x86_64/Win64 emitters, AOT, compile
  cache, guard-page bounds elision, fuel/interrupt sandbox) at zero
  implementation cost; measured 44× over interp [MEASURED-here]. Walls
  [INFERRED]: (1) **heap separation** — cljw's NaN-box values (44-bit ptr,
  non-moving GC) are invisible to zwasm linear memory; fine-grained Clojure
  ops crossing the boundary pay tens-of-ns host imports per object access,
  more than the few-ns dispatch they replace: fine-grained offload cannot
  win. (2) Escape (i): move Clojure data into the wasm heap as WasmGC
  types — technically open (zwasm is GC-spec-complete) but is a de-facto
  heap duplication/migration colliding head-on with F-004/F-006 — a
  depth-4 surgery on the finished form, against a conservative-scan GC of
  unmeasured performance; not recommended now. (3) Escape (ii):
  **coarse-grained kernel offload** (numeric loops, string building, hash)
  with one buffer copy at the boundary — feasible today under `.auto`,
  no Component/WIT needed; but it does not touch dispatch/call, so the
  11.5× main battlefield does not move; profile-side ceiling ≈
  collections+equal/hash ~4.5% [INFERRED from R0 profile]. (4) Ceiling:
  even fully offloaded, zwasm-jit sits 1.5–3.9× under Cranelift-class —
  likely not enough to beat JVM C2 [MEASURED-cited → INFERRED]. Verdict:
  A1 covers FFI/guest-execution speed (done) and kernel offload (modest);
  **it is not the mechanism that erases 11.5×**.
- **Option A2 — borrow zwasm's JIT substrate as a direct cljw-bytecode
  codegen backend, bypassing wasm entirely.** No heap-separation problem;
  native code touches NaN-box values directly. Fact check: **this plan
  exists in no document today** (ledger / zwasm ADR-0200 / zwasm ROADMAP
  checked); cljw has ADR-0151's execution-verified ARM64 substrate, the
  call-ABI micro-lever rejected at 3–4.5%, broad-JIT user-fenced
  [MEASURED-here]. Assessment [INFERRED]: technically sounder than A1
  (zero boundary cost, Winch-class baseline straight onto cljw bytecode),
  but zwasm's emitter is canned wasm-opcode→machine-code sequences —
  reusing it for cljw bytecode is closer to "reimplementation under the
  same design doctrine" than "reuse"; what transfers is know-how
  (single-pass-no-regalloc yields, guard-page tricks, AOT serialization
  format). Expected position per the RFC numbers: large improvement over
  interp, 1.1–1.5× under optimizing — **the only route that directly
  attacks rush-hour's 45%+ interpreter structural cost.** The prime
  candidate when the broad-JIT user fence opens.
- **Option B — the WasmGC compile route (ClojureWit-shaped)**: buys
  V8/wasmtime optimizing tiers for free, GC for free, component
  distribution (polyglot embedding); measured promising (boxed arithmetic
  0.31× JVM, V8 generic dispatch passing) [MEASURED-cited]. Loses:
  dynamism (§6.6 — interpreter bundling or two-mode), host GC/engine
  maturity risk (wasmtime GC correctness-stage; 5–6× browser spread),
  canonical-ABI copy costs at the seam, and cold start requires bringing
  an engine (bundling V8 ≈ tens of MB) — **"small single binary, instant
  start" does not come out of B alone** [INFERRED]. Relationship verdict
  [INFERRED]: not a competitor but **two faces of the same north star** —
  §8.

---

## 7. What it would actually take — the ladder of structural levers

This is the report's centerpiece: every proven technique from §§4–6 mapped
onto cljw's constraint set, ordered as a ladder. Each lever carries (a) its
evidence (which runtime proved it, with what measurement), (b) its expected
attack surface in cljw's profile, (c) its complexity / binary-size cost, and
(d) its refutation conditions — what result would prove it wrong.

**The constraint envelope every lever must fit** (from §3.4): F-004 NaN-box
+ non-moving 44-bit pointers; F-006 non-moving mark-sweep; F-012
dual-backend equivalence (VM production / tree_walk oracle); ~7.4 MB
ReleaseSafe budget with ceiling gate (ADR-0172/0132); eval / REPL / var
redefinition fully preserved. A key enabling reading [INFERRED, R1b]:
**tiers and caches added *inside* the VM backend do not break F-012** —
the oracle checks semantic equality, and specialization→deopt preserves
semantics by construction, so the equivalence gate remains the safety net
rather than a blocker.

**The profile being attacked** [MEASURED-here]: dispatch ~23% ·
bindCallFrame ~16% · TLV ~8% · call machinery ~6.5% · alloc
(malloc/memset/free_pool) ~6% · equal/hash + seq + collections ~7% · GC
~3.8%.

### Tier 0 — done, and refuted (do not re-run)

Already banked:

- **ADR-0184** (Function = variable-length GC cell): **−26%** on rush-hour
  at its own landing (16.5 → 12.3 s); the cumulative campaign arc from
  v1.9.0 is 17.9 → 12.3 s (−31%) [MEASURED-here]. Its Alt 3
  (template/closure split) is the named finished form — i.e., Tier 1's
  flagship lever is already the repo's declared destination.
- **ADR-0131 2a operand arena**: **~25% win** (fib 56→41 ms) — landed
  [MEASURED-here].
- **O-055 budget-TLV hoist**: −2.3% [MEASURED-here].

Refuted — recorded so no future cycle re-runs them:

| Experiment                           | Result                           | Verdict                                            |
|--------------------------------------|----------------------------------|----------------------------------------------------|
| TraceRef per-call TLV cache          | neutral [MEASURED-here]          | closed                                             |
| GC threshold multiplier 2×→4×     | neutral [MEASURED-here]          | closed                                             |
| bindCallFrame selective nil-init     | −0.6%, noise [MEASURED-here]     | closed                                             |
| ADR-0131 2b call-flatten             | neutral [MEASURED-here]          | closed                                             |
| ADR-0151 call-ABI micro-lever        | ~3–4.5% ceiling [MEASURED-here] | rejected as micro-lever; substrate retained        |
| stepOnce-prologue safety-point polls | near-free [MEASURED-here]        | non-target (matches quickjs-ng poll design, §4.1) |

The Tier 0 lesson, cross-confirmed by CPython's corrected tail-call story
(§4.3: dispatch-mechanism swap alone = 3–5% geomean [MEASURED-cited]):
**constant-factor levers on the current structure plateau at ~12.2 s; the
remaining ceiling is structural.**

### Tier 1 — interpreter structure (no machine code, no new subsystem)

#### Lever 1a. Call/frame redesign: "argument write position = callee frame" + frame reuse

- **Evidence**: unanimous across all six VMs (§4.1 Law 1 table): Lua's
  reused CallInfo + single-C-frame `startfunc`; Janet's fiber-slice frames
  with zero arg copies; Wren's arg-window-as-frame; quickjs-ng's
  caller-slot aliasing (`arg_buf = argv`); wasm3's compile-time slot
  offsets; LuaJIT's 2-slot in-stack frames. Independently: CPython's frame
  reform measured **3–7% + 1–3% overall, 1.7× on recursion micros**
  [MEASURED-cited]; jank's `dynamic_call` removal, −27% on raytrace
  [CLAIMED]; and the family-wide T4 verdict (§5.7): fix arity selection and
  argument transfer into compile-time shape.
- **Attack surface**: bindCallFrame ~16% + call machinery ~6.5% ≈ **22.5%
  of runtime** — the largest single addressable block. The closure side
  (per-closure snapshot copy, §4.1 capture table) is part of the same
  redesign: shared env or template/closure split kills the per-closure ×
  per-var copy.
- **Constraint fit**: fully inside F-004/F-006 (frames as slices of a
  contiguous growable value stack, not GC cells — nothing moves, nothing
  new is heap-allocated per call). F-012: the tree_walk oracle keeps its
  own frame representation; equivalence is behavioral, not structural.
  This *is* ADR-0184 Alt 3's direction — the finished form is already
  named; the lever is executing it.
- **Cost**: medium-large, one-time surgery on the VM's hottest data
  structure; size-neutral.
- **Refutation conditions**: if after landing, a profile shows
  bindCallFrame's successor cost still >8%, the layout failed to make args
  in-place (look for residual copies/initialization — Janet's only O(frame)
  cost was GC-mandated nil-fill; verify cljw's equivalent is bounded); if
  rush-hour improves <10% total, the block was less call-bound than
  the sample profile indicated.

#### Lever 1b. Dispatch restructuring: replicated indirect branches, operand-specialized opcodes, slow-path relocation

- **Evidence**: LuaJIT's in-repo record that de-replicating dispatch costs
  **10–30%** on certain benchmarks with -joff (vm_x64.dasc:221-237)
  [CLAIMED, in-repo, the strongest single dispatch datum]; Lua's `OP_MMBIN` slow-path-as-skipped-instruction (fast
  path pays zero for unused metamethods); LuaJIT/wasm3
  operand-kind-specialized opcodes (ADDVN/ADDNV/ADDVV, `_rs/_ss/_sr`);
  wasm3's tail-call threading pinning VM registers to physical registers
  (op = 5 instructions, CoreMark 8.1× wamr) [MEASURED-cited, in-repo].
  Counterweight: CPython's corrected result — swapping the dispatch
  *mechanism* alone is 3–5% geomean, compiler-dependent, sometimes ±0%
  [MEASURED-cited].
- **Attack surface**: the indirect-branch and fast/slow-path components of
  dispatch ~23%. Realistic take is a fraction of that bucket, not all of
  it [INFERRED].
- **Constraint fit**: Zig `@call(.always_tail)` is the musttail analogue
  for a wasm3-shaped design [INFERRED]; portability of always_tail across
  targets is the named risk. All VM-internal; F-012 untouched.
- **Cost**: small-medium for replication/specialized opcodes; a tail-call
  threading rewrite is a larger one-time restructuring. Size cost: opcode
  count growth is bounded (Lua covers a whole language in ~85 opcodes with
  operand-kind tricks).
- **Refutation conditions**: measure once after 1a — if replicated
  dispatch + specialized opcodes move rush-hour <3%, cljw's dispatch cost
  is dominated by handler bodies rather than branch prediction, and the
  lever closes (CPython precedent). Do not iterate on dispatch mechanism
  swaps; the 3–5% ceiling is measured.

#### Lever 1c. Superinstructions / fusion (profile-driven, few)

- **Evidence**: quickjs-ng `OP_get_loc0_loc1` ("individually very frequent
  AND often paired" — the repo's only profiling trace), `OP_add_loc`,
  `OP_call0..3`; Wren `LOAD_LOCAL_0..8` / `CALL_0..16` (arity folded into
  the opcode); wasm3 fused ops ("sometimes" effective [CLAIMED]); SCI's
  fused binding nodes: native bb 338→191 ms, **−43%** on the loop that
  motivated them [MEASURED-cited] — the direct Clojure-family precedent
  (D-386's standing direction).
- **Attack surface**: dispatch-count reduction inside the ~23% bucket;
  callee-header opcodes (LuaJIT `BC_FUNCF` model) also shave the call
  machinery slice.
- **Cost**: small per superinstruction; the discipline is to select by
  profile ("frequent AND paired"), not by intuition, and keep the set
  small.
- **Refutation conditions**: any superinstruction that does not show up as
  a measurable win on rush-hour or the micro suite gets removed — fusion
  is cheap to add and cheap to revert.

#### Lever 1d. Var-deref / TLV: delete lookups, don't cache them

- **Evidence**: Janet burns `def` bindings into function constants at
  compile time — calling a core function is one `LOAD_CONSTANT`
  (compile.c:307-397); JVM Clojure compresses non-dynamic var deref to one
  volatile load and deletes even that under direct linking (opt-out =
  `^:redef`/`^:dynamic`) [source-verified]; jank's literal-hoisting +
  var-deref-hoisting passes together cut generated core code >30%
  [CLAIMED]; CLJS erases vars entirely at compile
  time. The family-wide landing zone (§5.7 T3): deref ≤ 1 load, plus a
  hoist/direct-link escape hatch.
- **Attack surface**: dyld TLV ~8% [MEASURED-here]. The Tier 0 refutation
  matters here: the TraceRef per-call TLV *cache* was neutral — caching
  the lookup did not pay; the proven direction is reducing the **count**
  of lookups (hoisting, compile-time burning for non-redef vars), not
  their unit cost.
- **Constraint fit**: redefinability must survive — the JVM's opt-out
  model (direct-link by default, `^:redef`/`^:dynamic` escape) is the
  proven shape that preserves semantics; a redef invalidation path
  (recompile/patch affected sites, or an epoch check) keeps eval intact
  [INFERRED].
- **Cost**: medium (invalidation discipline); size-neutral.
- **Refutation conditions**: if hoisting/burning cuts TLV's profile share
  by less than half its ~8%, the residual TLV traffic is coming from
  something other than var deref (re-profile before iterating).

#### Lever 1e. Arena allocation for the small-object churn

- **Evidence**: quickjs-ng's arena — 31 size classes (16..512 B), 4 KB
  arenas, intrusive free lists; malloc ≈ 5 instructions, backing malloc
  once per arena refill (quickjs.c:258-320, 1709-1900) [source-verified].
- **Attack surface**: malloc/memset/memmove ~4% + free_pool hashmap lookup
  ~2.2% ≈ **~6%**.
- **Constraint fit**: sits under F-006's 3-tier allocator as an
  implementation refinement; non-moving preserved.
- **Cost**: small-medium; size-neutral.
- **Refutation conditions**: if the free_pool hashmap lookup (2.2%) does
  not disappear into the size-class free list, the design missed the
  point; if total alloc share drops <3%, close the lever — GC at 3.8% and
  Lua-style non-moving generational GC remain explicitly **low-priority**
  (the six-VM lesson: allocation *rate* design beats collector
  sophistication, §4.1.7).

#### Lever 1f. Collections / reduce / chunk engineering (the bb lesson)

- **Evidence**: bb holds 2.3× vs the JVM on rush-hour *while interpreting*
  because its stdlib is compiled, direct-linked JVM Clojure with the full
  §5.1 engineering [MEASURED-here + INFERRED]; the JVM's specific tricks
  are enumerated and source-cited in §5.1 (tail array, POPCNT HAMT,
  keyword array-maps to 64 entries, transients with disabled thread
  checks, chunk-32 with virtual LongRange chunks, IReduce internal
  iteration, `into` via transient).
- **Attack surface**: equal/hash ~2.5% + seq ~2.3% + collections ~2% ≈
  **~7%** directly — but R1d's inference is that in collection-heavy
  workloads this engineering's *absence* also inflates the dispatch and
  call buckets (more VM-level operations per logical collection op), so
  the true reach is larger than the direct 7% [INFERRED].
- **Cost**: incremental, per-structure; no architectural risk; the one
  discipline is F-012 coverage for each fast path (internal reduce paths
  must stay behaviorally identical on both backends).
- **Refutation conditions**: per-structure micro benches (are-we-fast-yet
  style) that fail to move rush-hour indicate the workload's collection
  mix differs from the assumed one — re-profile.

**Tier 1 aggregate expectation** [INFERRED, back-of-envelope from the
profile]: levers 1a–1f address ~45% of runtime directly. If the unanimous
six-VM call design (1a) removes most of its 22.5% block, dispatch
restructuring + fusion take a conservative fraction of 23%, TLV halves,
and alloc halves, a **30–45% total reduction (12.3 s → ~7–8.5 s, 11.5× →
~6.5–8×)** is the evidence-aligned band — comparable to CPython's
interpreter-only +25–50% [MEASURED-cited analog]. That does not reach 1×;
it is the prerequisite floor for Tiers 2–3.

### Tier 2 — adaptive specialization + call-site caches (still no machine code)

#### Lever 2a. PEP 659-model adaptive specialization + quickening

- **Evidence**: CPython 3.11 **+25% average** whole-interpreter, calls
  +20%, method calls 10–20%, subscript 10–25% [MEASURED-cited]; 25–30% of
  executed instructions specializable [MEASURED-cited]. No machine code,
  ISA-independent, near-size-neutral; deopt = rewrite back to the generic
  instruction.
- **Attack surface**: cross-cutting — the specialized families for cljw
  would be arithmetic (already NaN-boxed; specialization removes tower
  dispatch), seq-step, collection access (nth/get/assoc), and calls.
- **Constraint fit**: F-012-compatible by the §7 preamble argument;
  dynamism preserved by construction (deopt).
- **Cost**: medium (per-family specialized variants + miss counters +
  rewrite protocol).
- **Refutation conditions**: CPython's measured floor applies — if cljw's
  specialization hit rates resemble SCI's primitive-specialization result
  (0 applicable sites across 5,555 tests [MEASURED-cited]) the lever
  dies; but SCI's failure was *primitive unboxing under dynamic dispatch*,
  not operator specialization — CPython succeeded on the same dynamic
  substrate, so the prior is favorable [INFERRED].

#### Lever 2b. Call-site caches for protocol dispatch / keyword lookup (basic form only)

- **Evidence**: Deegen — interpreter-internal IC is a major factor in
  beating LuaJIT's asm interpreter by +28% [MEASURED-cited]; Serrano &
  Feeley: no slowdown when unused, up to ~4× on cache-miss-heavy benchmarks
  [MEASURED-cited]; JVM Clojure's own 3-layer protocol cache and
  KeywordLookupSite thunks are the in-family reference design
  (source-cited §5.1); CLJS shows the alternative of translating dispatch
  into host-IC-friendly shapes. The **negative result is load-bearing**:
  arXiv 2502.20547 — polishing ICs past the basic form buys nothing on
  modern OoO CPUs [MEASURED-cited]. And §4.1's ladder warns: first check
  the lookup-*deletion* levers (compile-time resolution, interning +
  precomputed hash — cljw keywords should already be intern-compared,
  negative caches) before adding cache slots.
- **Attack surface**: protocol/multimethod dispatch, keyword lookup on
  maps, multimethod dispatch values — spread across the dispatch and
  collections buckets; same-call-site shape locality is the enabling
  assumption [INFERRED].
- **Cost**: small-medium — inline cache slots in bytecode; size cost
  bounded.
- **Refutation conditions**: monomorphic hit-rate instrumentation below
  ~80% on rush-hour-class workloads would gut the expected win (compare
  ClojureWit's B7 finding that specialization pays only above ~80% hit
  rate on V8-like speculative engines and ~26.6% on wasmtime-like ones
  [MEASURED-cited] — for an interpreter IC the relevant threshold is the
  cache-hit rate itself); stop at the basic form regardless.

**Tier 2 aggregate expectation** [INFERRED]: CPython's +25% analog on top
of the Tier 1 floor. Combined Tier 1+2 evidence-aligned target: **rush-hour
into the ~4.5–6.5 s band (11.5× → ~4–6×)** — bb overtaken, the
interpreter ceiling approached. Passing bb is the falsifiable milestone:
if Tier 1+2 land and cljw still trails bb, the §5.3 inference (the gap is
core-on-VM-dispatch + collection engineering, not interpretation tax) was
wrong in a way that must be re-diagnosed before any Tier 3 spend.

### Tier 3 — a machine-code tier (the only route past the interpreter ceiling)

#### Lever 3a. Sparkplug-class baseline JIT over cljw bytecode

- **Evidence**: V8 Sparkplug +5–10% Speedometer / 5–15% main-thread — on
  an IC-complete system, with the explicit reading that IC-less systems
  gain far more (copy-and-patch's ~10× over interpreter as upper anchor)
  [MEASURED-cited]; JSC Baseline as prior art; Wasmtime RFC: baseline =
  15–20× faster compile, 1.1–1.5× slower code than optimizing
  [MEASURED-cited]; zwasm-jit's measured position 1.5–3.9× under
  Cranelift, 10–40× over its own interp [MEASURED-cited]; cljw's own
  measured 44× JIT/interp on wasm guest code [MEASURED-here].
- **The A2 route** (§6.7): borrow zwasm's JIT *doctrine* (single-pass, no
  regalloc, canned sequences, guard pages, AOT serialization), not its
  code, as a cljw-bytecode→native backend. No heap boundary; NaN-box
  values touched directly. **No document currently plans this**
  [verified]; broad-JIT is user-fenced; ADR-0151's substrate is the
  execution-verified seed. Sequencing per R1b/R1c: decide the zwasm JIT
  role split (gap II × III) first — this is the identified point of
  convergence, not a competing subsystem.
- **Attack surface**: the whole residual interpreter structural cost —
  dispatch + decode removal is precisely what a template JIT buys
  [MEASURED-cited, v8.dev]. Keeping the interpreter's frame layout
  (Sparkplug's key design) preserves the OSR/debug/deopt story and — for
  cljw — keeps the tree_walk oracle meaningful (F-012: the JIT tier is a
  third executor of the same semantics, checkable by the same diff
  oracle) [INFERRED].
- **Cost**: large — codegen per ISA (ARM64 first), OSR, deopt, debugging;
  binary size grows by the emitter (zwasm's arm64 emitter is the ~691 KB
  scale reference [MEASURED-cited, file size]), which must fit the 7.4 MB
  ceiling; ReleaseSafe stays non-negotiable (ADR-0132).
- **Refutation conditions**: if Tier 1+2 leave <20% of runtime in
  dispatch+decode, the baseline JIT's take shrinks below its complexity
  (the V8 situation); measure interpreter residency first. A prototype on
  one hot function class (fib-shaped call kernels) should show ≥2× on
  those kernels before committing to full coverage [INFERRED].

#### Explicitly rejected machine-code shapes (with the evidence)

| Shape                                    | Why rejected for cljw                                                                                                                        | Evidence                                                                                                                         |
|------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| **Tracing JIT**                          | rush-hour BFS = data-dependent branches every iteration = tracing's documented worst case; trace explosion grows memory faster than speed    | Bolz-Tereick primary [CLAIMED]; LWN trace-explosion case [CLAIMED anecdote]; CPython's own branchy-duplication problem [CLAIMED] |
| **Copy-and-patch**                       | Zig has no LLVM/ghccc stencil-extraction equivalent; stencil libraries hit the 7 MB budget directly; CPython's realized gain was ±0→4–12% | OOPSLA 2021 numbers vs CPython outcome [MEASURED-cited]                                                                          |
| **LBBV (YJIT model)**                    | took a world-class funded team years; its owners are migrating to method-SSA (ZJIT) citing ceiling + maintainability                         | Shopify/ZJIT record [MEASURED-cited + CLAIMED]                                                                                   |
| **Truffle partial evaluation**           | precondition stack (Graal + HotSpot-class GC + tens of person-years) incompatible with a solo 7 MB project                                   | PLDI 2017 + graaljs#879 [MEASURED-cited]                                                                                         |
| **WasmGC self-hosting of the cljw heap** | de-facto heap migration; head-on F-004/F-006 collision; zwasm GC-on-JIT performance unmeasured                                               | §6.7 A1 escape (i) [INFERRED]                                                                                                   |

### The trade-off table

| Lever                       | Expected win (evidence-aligned)                                                           | Dynamism (eval/redef)                          | Complexity (incl. F-012 upkeep)                                    | Binary size (7.4 MB budget)                        |
|-----------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------|--------------------------------------------------------------------|----------------------------------------------------|
| 1a call/frame redesign      | largest single block (~22.5% surface) [INFERRED]                                          | untouched                                      | medium-large, one-time; oracle unaffected (behavioral equivalence) | neutral                                            |
| 1b dispatch restructuring   | fraction of ~23%; 10–30% of the branch component [CLAIMED]                               | untouched                                      | small-medium (tail-call variant: larger)                           | neutral                                            |
| 1c fusion/superinstructions | small, additive [MEASURED-cited analog: SCI −43% on target loop]                          | untouched                                      | small, reversible                                                  | small growth                                       |
| 1d var/TLV lookup deletion  | up to ~8% bucket halved [INFERRED]                                                        | preserved via opt-out + invalidation           | medium                                                             | neutral                                            |
| 1e arena allocation         | ~3% of ~6% bucket [INFERRED]                                                              | untouched                                      | small-medium                                                       | neutral                                            |
| 1f collection engineering   | ~7% direct + indirect reach [INFERRED]                                                    | untouched                                      | incremental; per-path F-012 coverage                               | neutral                                            |
| 2a adaptive specialization  | +25%-class on the Tier 1 floor [MEASURED-cited analog]                                    | preserved (deopt)                              | medium                                                             | near-neutral                                       |
| 2b call-site caches (basic) | Deegen/Serrano-class contribution [MEASURED-cited analog]                                 | preserved                                      | small-medium                                                       | small growth                                       |
| 3a baseline JIT             | the remaining interpreter residency; 1.1–1.5× under optimizing ceiling [MEASURED-cited] | preserved (interpreter remains; JIT is a tier) | large; +1 executor under the F-012 oracle                          | emitter-scale growth (~0.5–1 MB class) [INFERRED] |

### The sequencing claim

1. **Tier 1 first** — it is the unanimous six-VM prescription, it is
   already the repo's named finished form (ADR-0184 Alt 3), and every
   later tier's win shrinks if the call/frame block is still fat
   (CPython's frame reform came *with* specialization, not after).
2. **Tier 2 second** — CPython proved the order works and the take is
   +25%-class with no machine code and no size cost.
3. **Only then Tier 3**, gated on (a) measured interpreter residency
   still being the majority cost, (b) the zwasm JIT role-split decision
   (gap II × III), and (c) the broad-JIT user fence opening. The A2 shape
   (zwasm-doctrine baseline over cljw bytecode) is the standing best
   candidate; A1 (kernel offload) remains a small, independent,
   already-unblocked win that does not move the main battlefield.

---

## 8. ClojureWasm × ClojureWit × zwasm — the triangle

R1e read the entire ClojureWit repository (`~/Documents/MyProducts/
ClojureWit`: README, CHANGELOG, roadmap, status, all 30 design docs,
bench/s0, corpus, src, 2026-08-06; last repo activity ~2026-07-30).

### 8.1 What ClojureWit is

Thesis — README.md:3: "**Clojure and WebAssembly, joined at the
interface.**" WIT (the Component Model IDL) as the seam, both directions:
call any-language components from Clojure as namespaces, and compile
Clojure namespaces to self-contained `.wasm` components callable from
Rust/Go/JS/Python. The founding differentiation (doc 0001:19-21):
"**Clojure has never been callable *from* another language ecosystem.**
JVM Clojure is callable from the JVM; ClojureScript from JavaScript. A
component is callable from anything."

Status: README says "pre-alpha. There is no compiler yet" — conservative
relative to reality [INFERRED, R1e]. Actual state (doc/status.md
2026-07-30): **S0 feasibility measured and closed; S1 complete**
(`cljwit.host`, 1,364 lines: bidirectional marshalling of every shipped
WIT type row, reflection-based export discovery, WASI deny-by-default,
resources both directions); **S2 half done** (project files, generated
namespaces, working nREPL via `bb repl` — CIDER-verified fib 20→6765);
**S3 has substance** (`cljwit.analyze` on tools.analyzer, 96 lines +
`cljwit.emit` WAT emitter, 628 lines; a 60-entry corpus diff-checked
against real `clojure` as oracle on wasmtime + V8 × dev/prod modes, and
verified in a real Chrome tab); **S4 entered** (a cljwit-compiled fib
component called from the JVM by cljwit.host; string-echo marshalling
slice with bump-arena `cabi_realloc` in the gate). Not yet: varargs,
seqs, in-language strings, collections, protocols (S5).

### 8.2 The S0 verdict numbers [MEASURED-cited, doc/design/0002 + 0010]

Hand-written WAT (no compiler involved), V8 (node 24/26) + wasmtime 47.0.1
lanes, JVM Clojure (OpenJDK 25) control, M4 Pro, n=20M, reps=20, median.

**Stop condition** (rewritten twice, final form roadmap:33-47): "Dispatch
overhead — B1 minus B1c, same lane, same build — **must be under 1 ns**"
(JVM Clojure's own dispatch overhead is 0.08 ns; direct calls ~1–2 ns on
both engines).

- **B1 monomorphic protocol dispatch (ns/dispatch)**:

| Lane        | B1c direct | B1i 0-load | B1L 1-load |              B1 3-load |
|-------------|-----------:|-----------:|-----------:|-----------------------:|
| JVM Clojure |      1.386 |         — |         — |                  1.504 |
| V8          |      0.737 |      0.783 |      0.813 | **0.865** (0.58× JVM) |
| wasmtime    |      2.346 |      2.475 |      8.326 | **8.434** (5.61× JVM) |

  Decisive finding: wasmtime's ~6.1 ns overhead is charged **entirely on
  the first load from the receiver** (0→1 load +5.85 ns; 1→3 loads
  +0.11 ns) — load-to-indirect-branch dependency; flattening the vtable
  would buy only 0.11 ns. Neither wasm-opt -O3 nor wasmtime 47's inliner
  moves it.
- **B2 megamorphic**: 10-type cost is wasmtime **+9%** vs JVM **+114%**
  (no thrashable cache in a vtable slot) — but wasmtime carries B1's
  monomorphic overhead, so absolute is 2.84× JVM; V8 degrades +122% yet
  stays 0.61× JVM.
- **B5 guarded specialization**: `br_on_cast` guard + direct call +
  generic fallback at 100% hit: wasmtime 2.390 vs floor 2.331 (below
  bench resolution), V8 0.733 vs 0.739 — **indistinguishable from the
  direct-call floor on both lanes → stop condition cleared**. At 2/11
  hits wasmtime is 12.37 ns, *worse* than generic 9.22 — "specializing a
  mis-analyzed site is worse than not specializing" (the cliff).
- **B7/B7b break-even**: specialization pays above **~26.6% hit rate on
  wasmtime, ~80% on V8** (the repo's own hygiene: ±a few points; the 3×
  lane ratio is the robust part); a
  single conservative 80% threshold regresses neither lane and recovers
  5–6 ns per applied site on wasmtime. Per-lane builds deferred to S3.
- **B3 boxed arithmetic (ns/add)**: JVM 2.982 / V8 0.927 / wasmtime 0.912
  — **both lanes 0.31× JVM = 3.2× faster** (overflow checks free:
  0.912 vs 0.917). Unboxed floor: JVM 0.109 vs 0.23–0.24 = **2.1–2.2×
  slower** (self-reported weakest number; C2 may have strength-reduced).
  The predicted profile — "win on dispatch-heavy and boxed arithmetic,
  lose where the JVM uses primitives" — confirmed in both directions.
- **B4 ref.cast**: depth is free (depth 2–5: 3.669→3.698 ns); the expense
  is **casting to a type that has subtypes**: leaf-type cast 0.09 ns vs
  cast-to-extended-type 2.80 ns = **30×** (+2.14 ns more under input
  diversity; V8 indifferent — Cranelift-specific). This *refuted* doc
  0004's "keep hierarchies shallow and wide" — corrected to "cast to
  leaves, keep the type set reaching each cast site small".
- **B8 boxed-i64 lane** (fib's n=46..92 domain, allocation per op): V8
  1.377 / wasmtime 1.993 ns — **both beat the JVM's boxed 2.964**
  (0.46× / 0.67×), 5–15× cheaper than predicted. B8i (real slow path
  present but untaken): V8 +~3%, wasmtime indistinguishable — the fixnum
  split survived its refutation condition.
- **Verdict (0010:14-15)**: "**Yes on both lanes, for production builds,
  at call sites the compiler can specialise precisely.** Every qualifier
  in that sentence is load-bearing." V8 passes with generic dispatch and
  beats the JVM on both dispatch benches; wasmtime fails generic by 6×
  and passes only guard-specialized. The honest residue: B7 measured hit
  *rate*, but the compiler-controlled quantity is **coverage** (fraction
  of sites analysis can prove specializable) — unmeasured, assigned to
  S3. None of the benches is a Clojure program (no seqs, no GC pressure);
  guard chains beyond one type are unpriced; all numbers from one arm64
  machine ("no number in this repo has been produced on x86_64 Linux").

### 8.3 Boundary and call costs [MEASURED-cited, docs 0007/0013/0014, B6]

- **Structural fact** (doc 0007:17-18): "No Canonical ABI that anything
  can execute lowers WasmGC references across a component boundary" (the
  GC-ABI pre-proposal exists; wasmtime 47 panics on it). Decision: **GC
  inside, linear memory at the seam** — Clojure heap is WasmGC; a
  dedicated linear memory + `cabi_realloc` serves the Canonical ABI;
  scalar-only exports are zero-cost; core modules *inside* one component
  share GC references freely.
- **B6 copy costs (4 KB payload, wasmtime)**: `(array i8)`→memory byte
  loop 2543.6 ns (0.621 ns/B); `(array i64)`→memory 8 B/iter **338.9 ns**
  (0.083 ns/B, 7.5× cheaper — a permitted representation lever);
  memory→`(array i8)` lift 2224.0; `memory.copy` (linear-language floor)
  **35.3 ns**; `array.copy` (GC→GC) 51.1 ns. WasmGC has **no bulk
  array↔memory copy instruction**, so lowering is an element loop — ~10×
  the linear-language floor (72× if naive); an instruction would recover
  a further 6.6×. But doc 0011 inverts the emphasis: with its measured
  library-lane per-call constant (~2.5 µs), **payloads under ~30 KB are
  call-dominated**; doc 0013 later re-measured the floor at ~0.4 µs
  (component-typed), which shrinks the call-dominated band accordingly.
  Kotlin (the nearest production precedent) crosses the boundary
  the same way — "B6's 10× is the frontier, not our deficiency" (0030).
- **Per-call costs** (same `add(i32,i32)`, ns/call): wasmtime core-typed
  floor **15.2–15.7** (Rust/C agree within 2%); JVM/FFM adds a flat
  ~27–31 ns (46.1) — so bindings stay pure Clojure; **component-typed
  279.4 = 18× the core call**, ~79% of it Canonical ABI lift/lower
  (typing back only ~10%); the real `cljwit.host` library measures
  **807.7 ns/call** ("recorded rather than optimised"). Instantiation:
  README's "~0.06 ms" = **56.9 µs** measured through cljwit.host
  (compile 1.6 ms for 2.4 KB to 19.2 ms for 103 KB, Cranelift; C-probe
  instantiate 0.02 ms). Dev loop: binaryen.js in-process assembly
  **1.28 ms/form** (18× faster than spawning wasm-tools parse at ~23 ms);
  wasmtime process start+run ~22 ms; `bb check` full gate ~1 s.
- Measurement-hygiene note the repo itself records: the first 0011
  numbers were an artifact (~1470 ns of reflective `MemorySegment.get`
  inside the instrument); "this machine varies up to 1.8× across
  processes — three significant figures must not be quoted across
  processes".

### 8.4 The relationship, in ClojureWit's own words (direct quotes)

- README.md:156-159 (Related): "**ClojureWasm — a sibling project in this
  org: a Clojure *runtime* in Zig that *executes* Wasm. ClojureWit is a
  *compiler* that *emits* Wasm. They compose: a component built with
  ClojureWit can be required by ClojureWasm.**"
- doc/roadmap.md:146-148: "**Not a Clojure runtime.** ClojureWasm is
  that, in this same org. It runs Clojure without a JVM and *executes*
  Wasm. ClojureWit *emits* Wasm and needs a JVM at build time only."
- doc 0001 (alternatives rejected): "**Extend ClojureWasm instead of
  starting a project.** … Different host, different lifecycle, different
  users. Sharing a repo would have coupled two things whose only overlap
  is the word 'Wasm'." And on the GC choice: "**Target core Wasm with our
  own GC** (the ClojureWasm approach). Rejected: WasmGC exists now, and
  shipping a GC costs both binary size and the engine's ability to
  optimize across our allocations" (0001:56-58).
- doc 0003:82-84: "We do not write a JIT. The sibling ClojureWasm project
  has one on its roadmap because it owns its engine; we do not own ours."
- doc 0005: "The sibling ClojureWasm project is the control group.
  Because it is a standalone Zig binary, it had to implement, itself: an
  nREPL server from bencode up …, deps.edn resolution, editor completion…
  Every one of those is free here, and every one of them is a place where
  behaviour can differ from real Clojure."
- ClojureWit's .claude/CLAUDE.md: "ClojureWasm (Clojure runtime in Zig)
  and zwasm solved adjacent problems and are worth reading for **what
  went wrong** — their design notes and debt ledgers are more useful than
  their code." (With the caveats: "Their conclusions are about *their*
  constraints… Inherited conclusions need re-deriving.")
- doc 0009:31 (two-mode design): "Dynamism is lost at the production
  boundary, deliberately."

### 8.5 Speed and distribution: the three routes side by side

| Property                 | cljw (native runtime)                                                    | ClojureWit component (WasmGC)                                                                                                                                                                                                                                                       | JVM Clojure (host)                    |
|--------------------------|--------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------|
| Real-workload throughput | 11.5× vs JVM today [MEASURED-here]; §7 ladder targets ~4–6× then JIT | Boxed arith 0.31× JVM (3.2× faster); unboxed floor 2.1× slower; dispatch 0.58× JVM on V8, 5.61× generic / ~floor specialized on wasmtime [MEASURED-cited]                                                                                                                      | 1× reference; C2 + §5.1 engineering |
| Single perf multiplier   | meaningful (one engine)                                                  | **explicitly refused**: "The engine ranking inverts with the workload — V8 is 9.8× faster than wasmtime on B1's dispatch and 3.3× slower on compute-bound linear-memory code. Any one number quoted about this project is wrong in one of the two directions." (roadmap:154-158) | meaningful                            |
| Cold start               | native + startup cache; held [MEASURED-here]                             | engine-dependent; instantiate 56.9 µs on a warm engine [MEASURED-cited]; bringing V8 ≈ tens of MB                                                                                                                                                                                  | JVM start, seconds-class              |
| Distribution unit        | single ~7.4 MB binary                                                    | `.wasm` component, callable from anything                                                                                                                                                                                                                                           | JVM + classpath                       |
| Dynamism                 | full eval/REPL/redef                                                     | dev mode full (per-form modules, var ledger, nREPL verified); **prod = closed world, deliberately**                                                                                                                                                                                 | full                                  |
| GC                       | own (F-006, non-moving)                                                  | engine's WasmGC (borrowed)                                                                                                                                                                                                                                                          | JVM's                                 |
| Engine ownership         | owns zwasm-embedded engine → can JIT                                    | "we do not own ours" → cannot JIT, compiles guarded ICs statically                                                                                                                                                                                                                 | owns C2                               |
| Build-time deps          | none                                                                     | JVM at build time only                                                                                                                                                                                                                                                              | JVM                                   |

### 8.6 Where they converge

1. **The WIT seam.** cljw's "require a component as a namespace" route
   (D-404/D-567) and ClojureWit's type mapping (doc 0012:
   record→keyword map, variant→`[:tag payload]`, result→`[:ok v]`/
   `[:err e]`, `map<K,V>` deliberately *not* a Clojure map — pair vector,
   because duplicate keys are legal and ordered) ride the same ABI. Risk
   named by R1e: if both sides decide the WIT↔Clojure value mapping
   independently, the same Clojure value gets two boundary
   representations — a place to align, not to compete [INFERRED].
2. **zwasm underneath both.** zwasm is already a spec-complete WasmGC
   host (§6.1) — the route "ClojureWit output → zwasm → embedded in cljw"
   is spec-open today; the practical gaps are components-through-the-JIT
   (zwasm D-500) and the v2.4.0→v2.4.1 pin bump that resolves cljw D-567
   [MEASURED-cited]. When zwasm runs WasmGC + tail calls through its JIT,
   the triangle closes: **dev in cljw's REPL, prod as a component, both
   on the same zwasm** — a single toolchain, and the most concrete
   reading of cljw's gap II × III north star [INFERRED, R1c §7.4].
3. **Shared lessons, both directions.** ClojureWit already imports:
   zwasm's Component Model sizing (v1 estimate ~5,600 lines → v2 actual
   **8,574** — +50%; wasmtime ~28k+10k), the retptr asymmetry bug
   ("zwasm's recorded bug", cited at component.clj:106), utf8-only
   shipping (zwasm D-502), and cljw's failure catalog (differential-
   oracle coverage lag — "mandatory-ness alone saved nothing; same-commit
   coverage is what does" — def ordering, varargs rest-mode, `+` vs
   `+'`). Flowing back: S0's engine-independent WasmGC findings
   (load-to-indirect-branch as the whole wasmtime dispatch cost;
   ref.cast-to-leaf 0.09 ns; the missing array↔memory bulk-copy
   instruction and the i64-width lever; rec-group structural identity and
   the `wasm-opt --closed-world` trap that folds shared-type `ref.test`
   to `i32.const 0`) and the REPL-on-Wasm design (per-form modules +
   rec-group type sharing + import/export var ledger + in-process
   binaryen.js at 1.28 ms/form) — the most concrete documented design
   for "hot reload without owning the engine" [MEASURED-cited +
   INFERRED]. For zwasm's JIT design specifically, B1/B5's conclusion —
   Cranelift has no adaptive tier, so guarded inline caches must be
   emitted statically — is a direct input on whether zwasm's JIT should
   speculate [INFERRED].

**Triangle verdict** [INFERRED]: complementary by construction and by
declaration. cljw = dynamic, instant-start, single-binary, *consumes*
Wasm; ClojureWit = static prod compilation, *becomes* Wasm (higher
throughput ceiling via borrowed optimizing tiers); zwasm = the engine
under both. The apparent positional overlap ("run Clojure fast on Wasm")
dissolves on the execution-model axis — interpret-and-embed vs
compile-and-borrow — and on the build-time-JVM axis for users.

---

## 9. Verification appendix

### 9.1 Label legend (restated)

- **[MEASURED-here]** — measured in this repository, this session (M4 Pro,
  ReleaseSafe, v1.9.0 + ADR-0184), or confirmed from in-repo SSOT
  (`.dev/` ledgers, ADRs, bench scripts).
- **[MEASURED-cited]** — the cited primary source performed the
  measurement: peer-reviewed papers, official release notes with data,
  vendor engineering blogs with methodology, sibling repos' committed
  bench results (zwasm docs/benchmarks.md, ClojureWit bench/s0 + design
  docs, SCI `doc/ai/adr/` measurements), in-repo disassembly listings.
- **[CLAIMED]** — vendor/README/docs/comment claims without independent
  re-run (including in-repo performance comments like LuaJIT's 10–30%
  dispatch-replication note, and all jank blog numbers).
- **[INFERRED]** — reasoning from source structure or cross-report
  synthesis. All of §7's expected-win arithmetic is INFERRED from
  MEASURED inputs and is falsifiable via the stated refutation
  conditions.

### 9.2 How each input was verified

- **R0 (anchor)**: all numbers measured this session or read from repo
  SSOT; every cljw claim in this report was checked against R0; nothing
  cljw-related is quoted from memory.
- **R1a (interpreters)**: source-level reading of shallow clones at
  `~/Documents/OSS/` (2026-08-05/06 HEAD): wasm3, wren, lua, LuaJIT,
  quickjs-ng 0.16.1, janet — with file:line citations for every
  structural claim. In-repo measured data exists **only in wasm3**
  (docs/Performance.md, docs/Interpreter.md); the other five repos commit
  no benchmark results, so their speed attribution is INFERRED from
  structure, with in-repo quantitative comments labeled CLAIMED.
- **R1b (JIT tiers)**: web primary sources, all fetched 2026-08-06;
  preference for official whatsnew/PEPs/vendor engineering blogs/papers;
  corrected numbers used where the record was corrected (CPython
  tail-call 10–15% → 3–5%).
- **R1c (Wasm substrate)**: local primary sources read in full
  (zwasm README/CHANGELOG/ADR-0200/docs/benchmarks.md, cljw
  `.dev/zwasm_capabilities.md`, ClojureWit doc 0010) + dated web sources.
- **R1d (Clojure family)**: source reading of local clones (clojure
  1.13.0-master-SNAPSHOT, clojurescript, babashka, sci, jank) with
  file:line citations; SCI's numbers come from its committed ADRs
  (MEASURED-cited); jank's numbers from its dated blog posts (CLAIMED —
  no independent re-run).
- **R1e (ClojureWit)**: full-repo read (README, CHANGELOG, roadmap,
  status, all 30 design docs, bench/s0, corpus, src); quotes are verbatim
  with doc:line anchors; the repo's own prediction-first bench
  methodology and 15-incident index raise confidence in its numbers.

### 9.3 Known gaps and stale spots (kept honest)

- The folk number "LuaJIT interpreter is 2–4× PUC Lua" is **not in the
  LuaJIT repository** — treated as external CLAIMED, and not load-bearing
  here.
- quickjs-ng's `docs/docs/diff.md:45` still advertises "Polymorphic
  inline caching"; **0.16.1 source contains no IC** (verified by grep) —
  the doc is stale; this report relies on the source.
- **zwasm component-instantiate cost is unmeasured** (one hyperfine p2
  fixture data point would close it).
- ClojureWit's specialization **coverage** (vs hit rate) is unmeasured —
  its own S0 residue, assigned to S3; and "no number in this repo has
  been produced on x86_64 Linux" (ClojureWit's own disclosure).
- ClojureWit's B-numbers come from one M4 Pro; its own hygiene rule
  ("up to 1.8× process-to-process variance; never quote 3 significant
  figures across processes") applies to any reuse of them.
- Wren's comparison table dates to ~2014; LuaJIT and the compared VMs
  have all moved since [CLAIMED, dated].
- §7's aggregate expectations (Tier 1: −30–45%; Tier 1+2: to ~4–6×) are
  arithmetic over the sample profile plus measured analogs from other
  systems — they are targets with refutation conditions, not promises.

### 9.4 Facts that fell out of the research and belong in the ledger

(Recorded here because this report is code-change-free; each is a
candidate ledger/action item, not an action taken.)

1. **Pin bump zwasm v2.4.0 → v2.4.1 resolves cljw D-567** (multi-export
   component validation; user-gated) [MEASURED-cited, zwasm CHANGELOG].
2. `.cwasm` + `--cache` embedding-API adoption evaluation is still open
   in the capability ledger (guest cold-start axis).
3. Kernel offload (A1-iii) should be measured before belief: profile
   ceiling ≈ collections+equal/hash ~4.5% → low priority [INFERRED].
4. zwasm component-instantiate cost: measure once (gap §9.3).

### 9.5 Adversarial verification passes (2026-08-06)

After the draft was written, two independent adversarial fact-check passes
ran over it ("wrong until the source confirms it" stance), and **every
finding has been applied in place in this document**:

- **R4a — local claims** (`R4a-local-verify.md`): ~150 discrete claims
  checked against in-repo SSOT, zwasm, ClojureWit, and the
  `~/Documents/OSS/` clones. **3 WRONG found and fixed**: (1) ADR-0131 2a
  operand arena was a landed **~25% win** (fib 56→41 ms), not a refuted
  slowdown; (2) the −31% figure is the cumulative campaign arc from
  v1.9.0, while ADR-0184's own landing is 16.5 → 12.3 s (−26%); (3)
  LuaJIT ARM64 runs dual-number mode — only x64 defaults to double-only.
  Plus 4 IMPRECISE fixes (quickjs tag-enum file cite, the 0011/0013
  call-constant pairing, the LuaJIT dispatch-replication quote's scope
  qualifier, B7's over-precise "80.1%").
- **R4b — web claims** (`R4b-web-verify.md`): 39 numbered findings across
  ~45 web-sourced claim clusters. **3 WRONG found and fixed**: (1) the
  Serrano & Feeley CC 2019 "≤25%" figure does not exist in the paper —
  the actual result is ~0 to ~4× gains on cache-miss-heavy benchmarks;
  (2) the plb2 Ruby row is CRuby 3.3 **with YJIT**, not the interpreter;
  (3) the "10–100×" figure belongs to the jit-interface Explainer's
  motivation, not the Flycast writeup (Flycast: 2 FPS → 60 FPS). Plus the
  imprecise citations relabeled (Mike Pall lua-l primary, PEP 836 for the
  4–12%, borkdude blog for "very contextual", trace-explosion anecdote
  label, ZJIT charts-only, jank two-pass >30%) and the unverifiable
  figures removed or marked [unverified] (MPLR 15–19%, squint ~10 KB,
  wasm_of_ocaml "avg +30%", WasmGC ~92% traffic, jit-interface
  "stalled").

---

## 10. Sources

### 10.1 Local primary (all read 2026-08-05/06)

- This repo: `private/research/fastest-scripting/R0-cljw-anchor.md`
  (session measurements + SSOT extracts); `.dev/zwasm_capabilities.md`
  (pin v2.4.0, `.auto` adoption D-488, D-500/D-567, 44× JIT/interp);
  `.dev/debt.yaml` D-386/D-450; ADR-0131/0132/0151/0172/0184;
  `project_facts.md` F-004/F-005/F-006/F-011/F-012.
- `~/Documents/MyProducts/zwasm`: README.md, CHANGELOG.md (v2.4.1,
  2026-08-04), ADR-0200,
  docs/benchmarks.md (M4 Pro, hyperfine, ReleaseFast).
- `~/Documents/MyProducts/ClojureWit`: README.md, doc/roadmap.md,
  doc/status.md (2026-07-30), doc/design/0001–0030 (esp. 0002 S0
  measurements, 0003, 0004, 0005, 0007, 0009, 0010 verdict, 0012, 0013,
  0014, 0022, 0026, 0027, 0028, 0029, 0030), bench/s0/, corpus/,
  src/cljwit/ (host.clj, component.clj), refs.json, tools.json,
  .claude/CLAUDE.md.
- `~/Documents/OSS/` shallow clones (2026-08-05/06 HEAD): wasm3
  (m3_exec.h, m3_exec_defs.h, m3_compile.c, m3_config_platforms.h,
  docs/Interpreter.md, docs/Performance.md); wren (wren_vm.c,
  wren_value.h/.c, wren_compiler.c, wren_primitive.h, wren_opcodes.h,
  doc/site/performance.markdown); lua @ 7579fc9 (lvm.c, ljumptab.h,
  lobject.h, ldo.c/.h, lfunc.c, ltable.c/.h, ltm.h, lgc.c, lstate.h,
  lopcodes.h, lstring.h, makefile); LuaJIT @ 1edc3e52b (vm_x64.dasc,
  vm_arm64.dasc, lj_obj.h, lj_frame.h, lj_dispatch.h, lj_opt_narrow.c,
  lj_opt_loop.c, lj_record.c, doc/luajit.html); quickjs-ng 0.16.1 @
  954dc53 (quickjs.c, quickjs.h, docs/docs/diff.md); janet @ f362e8f
  (vm.c, fiber.c, compile.c, struct.c, gc.c, janet.h); clojure
  1.13.0-master-SNAPSHOT (Compiler.java, Var.java, IFn.java,
  Numbers.java, Util.java, PersistentVector.java, PersistentHashMap.java,
  PersistentArrayMap.java, LongRange.java, Range.java,
  MethodImplCache.java, KeywordLookupSite.java, core.clj,
  core_deftype.clj, protocols.clj, build.xml); sci @ e4ab8e9
  (doc/ai/adr/ 0001–0018, impl/types.cljc, impl/analyzer.cljc,
  impl/fns.cljc, impl/interpreter.cljc, lang.cljc, impl/vars.cljc,
  impl/namespaces.cljc, impl/records.cljc, impl/reflector.cljc);
  babashka @ be81e9c (project.clj, script/compile, main.clj,
  impl/classes.clj, impl/fs.clj); clojurescript (compiler.cljc,
  core.cljc, core.cljs, closure.clj, benchmark_runner.cljs); jank
  (object.hpp, visit.hpp, detail/type.hpp, obj/jit_function.hpp et al.,
  CMakeLists.txt, third-party/bdwgc); zware; wit-bindgen.

### 10.2 Interpreters & dispatch (web)

- https://luajit.org/luajit.html — LuaJIT design notes (fetched
  2026-08-06)
- http://lua-users.org/lists/lua-l/2011-02/msg00742.html — Mike Pall,
  "Why is LuaJIT's interpreter fast?" (lua-l, 2011-02) — primary
- https://news.ycombinator.com/item?id=8605225 — secondary HN discussion
  of Pall's statements (fetched 2026-08-06)
- https://sillycross.github.io/2022/11/22/2022-11-22/ — Deegen / LuaJIT
  Remake, +28% over LuaJIT interp (2022-11-22)
- https://blog.nelhage.com/post/cpython-tail-call/ — the tail-call
  interpreter correction (2025-03)
- https://fidget-spinner.github.io/posts/apology-tail-call.html — Ken
  Jin's correction to 3–5% (2025-03)

### 10.3 CPython (web)

- https://docs.python.org/3/whatsnew/3.11.html — PEP 659 +25%,
  per-instruction table, frame/call reform (fetched 2026-08-06)
- https://peps.python.org/pep-0659/ — specializing adaptive interpreter
- https://peps.python.org/pep-0836/ — JIT next steps
- https://lwn.net/Articles/977855/ — Bucher on copy-and-patch (2024-06)
- https://lwn.net/Articles/1029307/ — CPython perf status, ~50%
  cumulative, JIT 4–12% (2025-07)
- https://lwn.net/Articles/1013581/ — tail-call correction coverage
- https://github.com/python/cpython/pull/128718 — tail-call interpreter
  PR
- http://fredrikbk.com/copy-and-patch.html and
  https://dl.acm.org/doi/10.1145/3485513 — Xu & Kjolstad, OOPSLA 2021

### 10.4 Ruby (web)

- https://dl.acm.org/doi/10.1145/3486606.3486781 — YJIT, VMIL 2021
- https://shopify.engineering/ruby-yjit-is-production-ready — Ruby 3.2,
  railsbench +38%, prod 5–10% (2023-01-17)
- https://dl.acm.org/doi/10.1145/3617651.3622982 — YJIT production
  context (MPLR 2023; paper body inaccessible — the 15–19% figure is
  unverified)
- https://railsatscale.com/2025-05-14-merge-zjit/ — ZJIT merge
- https://railsatscale.com/2025-12-24-launch-zjit/ — ZJIT launch
  rationale (2025-12-24)
- https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/

### 10.5 V8 / JSC / Truffle / tracing (web)

- https://v8.dev/blog/sparkplug — baseline JIT design + numbers (2021-05)
- https://v8.dev/blog/maglev and https://v8.dev/blog/holiday-season-2023
  — Maglev numbers
- https://webkit.org/blog/10308/speculation-in-javascriptcore/ (2020) and
  https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html — JSC tiers
- https://chrisseaton.com/truffleruby/pldi17-truffle/pldi17-truffle.pdf —
  Truffle, PLDI 2017
- https://github.com/oracle/graaljs/issues/879 — GraalJS vs V8 status
- https://pypy.org/posts/2025/01/musings-tracing.html — Bolz-Tereick on
  tracing (2025-01)
- https://lwn.net/Articles/1029843/ — trace explosion case (2025)
- https://elmord.org/blog/?entry=20191114-sbcl-chez — SBCL vs Chez (2019)

### 10.6 Inline caches / shapes (web)

- https://mathiasbynens.be/notes/shapes-ics (2018) — canonical explainer
- https://www-sop.inria.fr/members/Manuel.Serrano/publi/sf-cc19.pdf —
  Property Caches Revisited (CC 2019)
- https://arxiv.org/abs/2502.20547 — the negative result on IC polishing
  (2025)

### 10.7 Benchmark landscapes (web)

- https://github.com/attractivechaos/plb2 (2024-01) and
  https://devclass.com/2024/01/04/how-fast-is-your-programming-language-new-contest-and-benchmarks-spark-debate/
- https://github.com/smarr/are-we-fast-yet (DLS 2016)
- https://speed.python.org and https://speed.yjit.org — live dashboards

### 10.8 Wasm substrate (web, fetched 2026-08-06)

- https://github.com/bytecodealliance/rfcs/blob/main/accepted/wasmtime-baseline-compilation.md
  — baseline 15–20× compile / 1.1–1.5× slower code
- https://github.com/bytecodealliance/wasmtime/blob/main/winch/README.md
- https://github.com/bytecodealliance/wasmtime/issues/10102 — Pulley
  tracking (2025-01)
- https://arxiv.org/pdf/2505.22610 — TPDE (Winch/Cranelift compile-speed
  ratios)
- https://bytecodealliance.org/articles/wasmtime-and-cranelift-in-2023 —
  hostcall ~10 ns
- https://bytecodealliance.org/articles/wasmtime-10-performance — few-ns
  calls, ~5 µs CoW instantiation (2022)
- https://bytecodealliance.org/articles/wasmtime-27.0 — GC complete
- https://bytecodealliance.org/articles/wasmtime-gc — correctness-first
  admission
- https://github.com/bytecodealliance/wasmtime/releases/tag/v46.0.0 —
  copying collector default
- https://developer.chrome.com/blog/wasmgc — Chrome WasmGC default
- https://web.dev/blog/wasmgc-wasm-tail-call-optimizations-baseline —
  browser ship status
- https://tarides.com/blog/2025-02-19-the-first-wasm-of-ocaml-release-is-out/
  — native ×2, jsoo 2–8×
- https://wingolog.org/archives/2026/04/09/wastrel-milestone-full-hoot-support-with-generational-gc-as-a-treat
  — Hoot AOT 4.44 s vs Guile ~3.5 s; browsers 5–6× (2026-04-09)
- https://www.wingolog.org/archives/2022/08/18/just-in-time-code-generation-within-webassembly
  — Harvard constraint + late linking (2022-08-18)
- https://github.com/WebAssembly/jit-interface/blob/main/proposals/jit-interface/Explainer.md
- https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md
- https://wasi.dev/roadmap and https://wasi.dev/releases/wasi-p3 — WASI
  0.3.0 (2026-06-11), 1.0 target
- https://github.com/bytecodealliance/wizer — 1.35–6× init speedup
- https://www.infoq.com/news/2025/12/cloudflare-wasm-python-snapshot/ —
  10 s → 1 s (2025-12)
- https://www.fastly.com/blog/how-compute-edge-is-tackling-the-most-frustrating-aspects-of-serverless
  — "100x faster startup" framing; the 35.4 µs figure itself is from
  Fastly's launch press release:
  https://www.fastly.com/press/press-releases/fastly-expands-serverless-capabilities-launch-compute-edge
- https://www.kmpship.app/blog/kotlin-wasm-and-compose-web-2025 —
  Kotlin/Wasm claims
- https://github.com/nasomers/flycast-wasm/blob/main/TECHNICAL_WRITEUP.md
  — late-linking dynarec, 2 FPS → locked 60 FPS (the "10–100×" figure is
  the jit-interface Explainer's motivation, not Flycast's)

### 10.9 Clojure family (web)

- https://jank-lang.org/blog/2023-08-26-object-model/ — object model
  rewrite, raytrace 36.96 vs 69.44 ms
- https://jank-lang.org/blog/2024-11-29-llvm-ir/ — move to LLVM IR
- https://jank-lang.org/blog/2026-05-08-optimization/ — custom IR; fib 35
  5,522→114 ms
- https://jank-lang.org/blog/2026-06-01-optimization/ — raytrace
  8.10→2.37 s; var-deref hoisting
- https://jank-lang.org/blog/2026-03-06-great-start/ — alpha status; LLVM
  22 startup incident
- https://github.com/squint-cljs/squint — README (fetched 2026-08-06)
- https://github.com/squint-cljs/cherry
- https://blog.michielborkent.nl/porting-cljs-project-to-squint.html
- https://github.com/Tensegritics/ClojureDart/blob/main/doc/differences.md
  (fetched 2026-08-06)
