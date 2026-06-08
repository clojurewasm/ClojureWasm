# ADR-0119 — Callable naming surface (restore fn names dropped in the v1 redesign)

- **Status**: Proposed → Accepted (2026-06-08)
- **Depends on / feeds**: ADR-0118 (error display) cycle 3 (`Trace:`) consumes
  the names this ADR restores. This ADR is the foundation; the trace is one
  consumer (`pr`/metadata are others).
- **Supersedes the cycle-3 framing in**: ADR-0118 Decision B + the cycle-3 plan
  note's Alt-2 lean. The frame-NAME source is now "name on the value" (Alt 3),
  not the two-call-site Var read (Alt 2) — see Decision + Alternatives.

## Context — a redesign regression, verified against the textbooks

cw v1's `Function` (tree_walk.zig:129) carries **no name and no defining_ns**
(only `header / slot_base / methods / variadic / closure_bindings`); the
analyzer `FnNode` (node.zig:212) is likewise nameless. So a running function
does not know its own name. This was found while scoping the cycle-3 stack
trace: a trace needs "which of MY fns was running", which the fn value cannot
answer.

This is a **regression introduced by the v1 ground-up redesign**, not an
inherent design choice — verified in the reference clones:

- **cw v0 HAD it**: `FnProto.name: ?[]const u8` (v0 chunk.zig:133, bytecode),
  `Closure.fn_node.name` (treewalk), `Fn.defining_ns` (v0 value.zig:869). v0
  could render `<ns>/<fn>` trace frames (`"anonymous"` fallback).
- **Clojure JVM**: EVERY fn gets a compile-time name baked into its class name
  (`Compiler.java:4558-4569`): named → `foo__<id>`, **anonymous → `fn__<id>`**;
  recovered in traces via `Compiler/demunge`.
- **Babashka / SCI** (the closest analog — JVM-less interpreter): the fn carries
  its name via metadata + the resolved Var symbol captured at the call boundary.

The redesign focused on NaN-boxing / GC / value representation and silently
dropped the name field; nothing forced it to be carried forward. This ADR
restores it as a **foundational** capability (traces + `pr` + future
`(:name (meta #'f))`), matching all three textbooks.

### The callable surface is wider than `.fn_val` — and most kinds already self-name

cw v1 has many IFn-implementing callables (the `treeWalkCall` switch,
tree_walk.zig:1040) plus a separate interop-method family. Crucially, **only
plain `.fn_val` is missing its name** — the siblings already carry theirs:

| callable                                                         | name source                                                   | trace disposition           |
|------------------------------------------------------------------|---------------------------------------------------------------|-----------------------------|
| `.fn_val` (plain user fn)                                        | **NONE today → restored here**                               | PUSH                        |
| `.builtin_fn`                                                    | immediate NaN-boxed ptr (value.zig:221) — cannot hold a name | ELIDE                       |
| `.multi_fn`                                                      | `MultiFn.name: Value` (multimethod.zig:63)                    | PUSH                        |
| `.protocol_fn`                                                   | `descriptor.fqcn()` + `methodName()` (protocol.zig:56,132)    | PUSH                        |
| `.keyword`/`.symbol` as IFn                                      | the value itself                                              | ELIDE (data accessor)       |
| `.array_map/.hash_map/.hash_set/.vector/.sorted_map/.sorted_set` | none (accessor)                                               | ELIDE                       |
| `.var_ref`                                                       | `Var{ns,name}` (env.zig:80-83); re-dispatches                 | name the var / skip         |
| `.typed_instance`/`.reified_instance` IFn `-invoke`              | TypeDescriptor fqcn                                           | PUSH (optional)             |
| interop `(.m o)` / `(T/m x)`                                     | InteropCallNode method + descriptor (area D)                  | secondary family (deferred) |

That `.fn_val` is the **only** kind without a self-name is the consistency
argument that decides Alt 3 over Alt 2 (below): the siblings name from the
*value*, so plain fns should too.

### Scope: eval-phase runtime trace only

A trace is the **eval-phase** call stack. Macros are expanded away before
execution (macroexpand phase), so they never appear as runtime frames
(`(when x body)` shows `body`, not `when`). Special forms are control flow, not
callables — no frames. parse / analysis / macroexpand errors are located by
`Info.phase` + loc but are NOT framed by this mechanism (a macroexpansion trace
would be a separate, future concern). Record this so "why is there no `when`
frame" is not chased as a bug.

## Decision

Restore the name on the function **value** (Alt 3), give every callable a
uniform name resolver, and consume it in `pr` (Stage 1) and the `Trace:`
renderer (Stage 2).

1. **`FnNode` + `Function` gain `name: ?[]const u8` and `defining_ns:
   ?[]const u8`.** The name lives on the value, so the single shared choke
   point `treeWalkCall` can read it — this is Alt 3's win over Alt 2's two
   call-site reads.
2. **String ownership = borrow the analyzer arena** (`rt.load_arena`,
   session-lifetime), exactly as `FunctionMethod.params`/`body` already do — NOT
   `gpa.dupe`, NOT intern. Safe because cw v1 never resets the analyze/load
   arena mid-session (loader.zig:58, repl.zig:44). **This unwritten invariant
   (which `params`/`body` already silently ride) is hereby documented**: a
   future per-form-reset arena would UAF the name AND `params`/`body` — a shared
   invariant, not one this cycle introduces.
3. **Analyzer threading (3 cases now, 1 deferred)**: `analyzeDef` post-patches
   the analyzed `.fn_node` with `name_sym.name` + `env.current_ns.?.name` (covers
   `defn` macro→def→fn* AND raw `(def x (fn ..))`); `analyzeFnStar` mints a
   gensym `fn__<id>` (via existing `rt.gensym`) for anonymous fns + sets
   `defining_ns`; `analyzeLetfn` post-patches each binding's fn with the binding
   name. The `(fn name ..)` self-name case (lowered to `letfn*` today, so the fn
   stays anonymous) needs a new `analyzeFnStar` self-name arm — **deferred**
   (D-325), rare.
4. **`defining_ns` is display/metadata only.** v1 resolves every symbol to a
   `*const Var` at analyze time (analyzer.zig:698), so — unlike v0 — there is no
   per-call `current_ns` restore and none is needed. `defining_ns` feeds the
   trace `ns` column + future Var-fn metadata, nothing else. (Recorded so no one
   re-introduces a v0-style restore expecting it to matter.)
5. **Anonymous fns are gensym-named `fn__<id>`** (JVM parity), not left null.
6. **`calleeName(callee) -> ?{ns, name}`** resolver (Stage 2) switches over the
   callable tags per the table above; ELIDE arms (builtin / collection / bare
   keyword) return null = no frame. Builtins are elided from traces (the cw
   analog of clj's `RestFn`/`AFn` plumbing); their `pr`-name (reverse ptr→Var
   map) is a separate deferred concern (D-327).
7. **Single-choke-point push** at `treeWalkCall` entry: `calleeName` → `pushFrame`
   + `defer popFrame()`. `.var_ref` re-dispatches (tree_walk.zig:1061) — **skip
   the push on `.var_ref`** and let the inner `.fn_val` arm push (simpler than
   naming the var then deduping). Snapshot `getCallStack()` into a new
   `Info.trace` at `setErrorFmt` time; pop-on-both via `defer` (the
   recur/try/reduced-safe lifecycle from ADR-0118 Decision B).
8. **Interop method frames** (`(.m o)` / `(T/m x)`, a SECOND push family
   distinct from IFn dispatch) are **deferred** (D-326).

### Staging (each stage: lightweight local verify → full gate at the commit)

- **Stage 1 — naming threaded onto the value, verified white-box.** Struct
  fields + allocator literals (tree_walk.zig:263/301/399) + VM reconstruct
  (vm.zig:499) + analyzer threading (cases 1/3/4). Observable = unit + diff
  tests that read `Function.name`/`defining_ns` after analysis on BOTH backends
  (the VM reconstruct is the only divergence risk). **`pr`/`str` of a fn is
  deferred (D-328)**, not bundled here: a user-facing fn print form couples to
  the `(class fn)` label (currently the raw tag `fn_val`) and the `#object[…]`
  convention (AD-010), which is its own format + accepted-divergence design —
  orthogonal to the name *threading* this stage lands. Keeping Stage 1 to the
  threading + white-box verification avoids dragging a `(class fn)` redesign
  into the naming foundation. (Refinement found at implementation start,
  Step-0.6-style.)
- **Stage 2 — `Trace:` (ADR-0118 cycle 3).** `calleeName` resolver + revive the
  frame stack + push at `treeWalkCall` + `Info.trace` snapshot + renderer
  `Trace:` (text) + EDN `:trace` + decoder + `clearCallStack` per top-level
  form. Dual-backend parity diff test: nested named-fn error → identical trace;
  recur → a single frame (not N).
- **Stage 3 — deferred follow-ons** (debt rows D-325/326/327), not pushed here.

## Alternatives considered (Devil's-advocate, fresh-context fork)

A fresh-context DA was run on the frame-name source. Its three shapes (verbatim
intent) and the main-loop's choice:

- **Alt 1 — smallest-diff**: push at the single choke point, name from the
  callee *Value* (which has none for `.fn_val`) → render position-only / `"fn"`.
  *Rejected*: guts the feature (a trace of unnamed `fn (…)` lines is useless);
  Smallest-diff-bias smell — smaller precisely because it abandons the finished
  form.
- **Alt 2 — finished-form for the CURRENT representation (DA's recommendation)**:
  push at the TWO call sites (`evalCall` + `op_call`) where the Var name still
  exists, via a shared `info.pushFrame` helper. Sources the name where it lives
  (the Var, pre-deref). *Better*: no struct change; reuses the cycle-2.5
  parallel-array + `defer`-restore mechanism. *Costs*: two push sites = two
  parity surfaces; cannot name HOF-passed fns (`(map h coll)` → `h` is
  unrecoverable at the inner call); and crucially it makes `.fn_val` the **odd
  one out** — named from the call site while its siblings (`.multi_fn`,
  `.protocol_fn`) are named from the value.
- **Alt 3 — name on the value (DA's wildcard; CHOSEN)**: stamp `name` +
  `defining_ns` onto `Function` at def/analyze time. *Better*: the name travels
  with the callee everywhere (matching clj's class-name and v0's `proto.name`);
  makes the single-choke-point push viable; names anonymous fns via gensym; and
  — the deciding point the all-callables enumeration surfaced — makes `.fn_val`
  **consistent with its siblings** (all callables self-name on the value).
  *Costs*: touches the `Function` struct + FnNode + both backends' fn-allocation
  + the analyzer (the heaviest diff), and the string-ownership question (resolved:
  arena-borrow, area G).

**Main-loop choice: Alt 3, NOT the DA-recommended Alt 2.** This is an F-002
finished-form call, not a cycle-budget defer: (a) Alt 3 *restores a property v0
+ clj + SCI all have* (the regression framing — Alt 2 would entrench a
half-named callable surface); (b) the sibling callables already name from the
value, so Alt 3 is the *consistent* shape and Alt 2 leaves `.fn_val` an
exception; (c) the name-on-value is foundational beyond traces (`pr`, metadata).
The DA itself rated Alt 3 the genuine finished form and flagged its only real
cost as analyzer threading (a clean, separable unit), not GC (a static
`[]const u8` is GC-inert). Alt 2's HOF-naming claim is *unrecoverable* anyway,
so its supposed parity advantage over Alt 3 does not exist.

## Stage 2 implementation landed (2026-06-08)

The `Trace:` consumer landed on the Stage-1 names. As-built refinements:

- **`pushFrame` now returns `bool`** (recorded / dropped-at-cap). The push site
  pops only when it actually pushed, so push/pop stays balanced past the
  64-frame cap (an unconditional `defer popFrame` would underflow). This means
  the live `call_stack` self-zeroes between top-level forms (every `defer pop`
  runs on success AND error return), so **no production `clearCallStack` is
  needed** — a clean divergence from v0's defensive per-form clear. (Tests call
  `clearCallStack` for isolation only.)
- **Single-choke-point push at `treeWalkCall`** via `calleeFrame(callee, loc)`:
  `.fn_val`/`.multi_fn`/`.protocol_fn` push a value-sourced frame; everything
  else (builtin, data-as-IFn, `.var_ref`) elides. Both backends share it (VM
  op_call → vt.callFn). `Info.trace` is snapshotted into a threadlocal buffer at
  `setErrorFmt` (mirrors the `.context` snapshot), read by the renderer after
  the live stack has unwound.
- **Frame line = the CALL-SITE loc** (where the fn was invoked), not the
  execution-point line clj/v0 show (v0 patched the innermost frame to the IP via
  `updateTopFrame`). The precise error spot is already in the header + caret;
  the trace gives the call chain. Execution-point precision is deferred (D-334).
- **Text `Trace:` + EDN `:trace` land in lockstep** (ADR-0055), innermost-first,
  `  <ns>/<fn> (<file>:<line>)` with the same `file_label` fallback as the
  header. The post-mortem `render-error` decoder's `:trace` parse is deferred
  (D-333). Dual-backend parity + e2e (Case 11/12) cover both.
- **Post-happy-path verification backlog** (user-directed): trace under
  multi-threading (D-329), async (D-330), multi-module require chains (D-331),
  and the host/stdlib/user frame BOUNDARY — how far back to trace (D-332).

## Consequences

- A function knows its own name → traces, `pr`, and future `(:name (meta #'f))`
  all become possible. Stage 1 alone improves `pr` of fns.
- The string-ownership invariant ("analyze/load arena never resets mid-session")
  is now documented; `params`/`body` already depended on it implicitly.
- `defining_ns` is display-only — no resolution-correctness coupling.
- Builtins, collection-as-IFn, bare keywords, special forms, and macros are
  NOT framed (documented scope), so traces show only user-meaningful frames.
- Two backends touched → dual-backend parity diff tests are mandatory in the
  Stage-1 and Stage-2 commits (ADR-0036).
- Deferred: `(fn name ..)` self-name (D-325), interop method frames (D-326),
  builtin `pr`-name reverse map (D-327).

## Affected files (the 8 change groups; full file:line map in
`private/notes/phase14-cycle3-naming-investigation.md`)

1. Structs: node.zig `FnNode`, tree_walk.zig `Function`.
2. Allocators: tree_walk.zig:263/301/399 literals + vm.zig:499 reconstruct.
3. Analyzer: special_forms.zig `analyzeDef`, bindings.zig `analyzeFnStar` +
   `analyzeLetfn`.
4. Resolver: new `calleeName` in tree_walk.zig (Stage 2).
5. Push: tree_walk.zig:1047 `treeWalkCall` entry (Stage 2).
6. Renderer + lifecycle: print.zig / error_render.zig / render_error.zig +
   clearCallStack in the REPL/loader form loop (Stage 2).
7. Tests: diff_test.zig parity cases (both stages).
8. Print (Stage 1 consumer): the `.fn_val` render in print.zig.
