# ADR-0121 — Callable values print their name (`pr`/`str` of fn/multifn/protocol-fn)

- **Status**: Proposed → Accepted (2026-06-08)
- **Resolves**: D-328 (`(pr fn)`/`(str fn)` show the fn's name, not `#<fn_val>`).
- **Composes with**: ADR-0119 Stage 1 (fns carry name+defining_ns), AD-002
  (opaque refs print `#<…>` not clj's `#object[…]`), AD-003 (simple names),
  ADR-0059 (no JVM class). Adds AD-025.

## Context

`src/runtime/print.zig`'s value switch has no `.fn_val` / `.multi_fn` /
`.protocol_fn` arm, so all three fall through to `else => #<{tag}>` and leak the
internal Zig heap-tag name: `#<fn_val>`, `#<multi_fn>`, `#<protocol_fn>`. ADR-0119
Stage 1 already put `name`/`defining_ns` on the `Function` value (and `MultiFn`
carries a `name` Symbol, `ProtocolFn` a descriptor fqcn + method name), so the
information to print a meaningful name exists — it just is not wired to the
printer. clj prints `#object[user$boom__7 0xHASH "user$boom__7@…"]`; cljw drops
the JVM munged class + identity hash per AD-002/AD-003/ADR-0059.

`str` and `pr` of a callable reach the SAME site (`writeStrValue`'s `else` routes
to `printValue`), and clj renders them identically too — so there is no str↔pr
split to design.

### The zone constraint shapes the mechanism

`print.zig` is Layer 0 (runtime); `Function` lives in
`src/eval/backend/tree_walk.zig` (Layer 1). The zone rule forbids runtime/
importing eval/, and `printValue(w, v)` carries no `*Runtime`. BUT `MultiFn`
(`runtime/multimethod.zig`) and `ProtocolFn` (`runtime/protocol.zig`) are Layer-0
`extern struct`s — `print.zig` reads them directly. **Only `.fn_val` crosses a
zone.** (The Devil's-advocate assumed all three callables needed a cross-zone
hook and recommended generalising into a `tag_ops` display table; that premise is
factually wrong — two of the three are Layer 0 — so a `tag_ops` table would be a
one-registrant speculative generality. The DA's big-bang FORM insight is adopted;
its mechanism is corrected to a single-consumer accessor.)

## Decision

1. **Form (big-bang the whole callable family, no partial sweep):** every named
   callable prints `#<ns/name>`; an unnamed one prints `#<fn>` — AD-002's `#<…>`
   envelope with the raw tag replaced by the qualified name. Landed in one push
   for all three tags:
   - `.fn_val` → `#<defining_ns/name>` (via the accessor below) / `#<fn>`.
   - `.multi_fn` → `#<ns/name>` from the `MultiFn.name` Symbol (Layer-0 read).
   - `.protocol_fn` → `#<fqcn/method>` from the descriptor (Layer-0 read).
   `.builtin_fn` keeps `#builtin` (no name slot until D-327; the envelope is
   co-designed so D-327 only fills the name). Recorded as **AD-025** (the clj
   `#object[…]` divergence), `derives_from: AD-002 + AD-003 + ADR-0059`,
   pinned by a test exercising fn + defmulti + protocol-fn + anon.
2. **Mechanism (single cross-zone consumer):** a file-private
   `var fn_name_accessor: ?*const fn(Value) FnIdentity` + `setFnNameAccessor`
   in `print.zig`, installed from `tree_walk.registerGcHooks` (already called
   unconditionally for both backends from `driver.installVTable`). This mirrors
   the existing `runtime/error/info.zig` `context_provider` setter-injection (NOT
   a `pub var` vtable — ROADMAP §13). `print.zig` keeps the `#<…>` format policy
   in one place; the accessor returns only `{ ns, name }` data. `.multi_fn` /
   `.protocol_fn` need no accessor (Layer-0 direct read).
3. **`(class fn)` deferred:** it returns the raw tag `fn_val` today; a callable's
   class is a TypeDescriptor (type-system) concern, not a print concern.
   Co-designing it would drag TypeDescriptor design into a print cycle. Out of
   scope; AD-025 notes the print form implies no class decision.

### Scope / deferrals

- **Builtins (D-327):** `#builtin` stays; the `#<ns/name>` envelope is chosen now
  so D-327 only supplies the reverse ptr→name lookup, not a new form.
- **Layer-0 header-resident name (the DA's Alt 3):** moving `name`/`defining_ns`
  into a Layer-0-visible header would dissolve the accessor entirely, but it is
  depth-4 layout surgery (the `Function` offset assert, the VM `op_make_fn`
  reconstruct, and a NEW GC-rooting obligation on what is today a deliberately
  GC-inert static name). Disproportionate for a print fix; revisit when a
  non-print consumer (fn `class` / AOT name tables) first needs callable identity
  in Layer 0.

## Alternatives considered (Devil's-advocate, fresh-context fork — verbatim)

> **Devil's-advocate review of ADR-0121 / D-328 (fn name in `pr`/`str`)**
>
> Setup verified against source. `printValue` (`print.zig:595-678`) has no
> `.fn_val`, `.multi_fn`, or `.protocol_fn` arm — all three fall through to
> `else => |t| w.print("#<{s}>", .{@tagName(t)})` at L677, printing the raw
> heap-tag name (`#<fn_val>` / `#<multi_fn>` / `#<protocol_fn>`). `.builtin_fn`
> at L601 already prints `#builtin`. `writeStrValue` (L88-156) has no `.fn_val`
> arm either; its `else` (L154) routes to `printResult` → `printValue`, so
> **`str` and `pr` of a fn already share the same rendering site** — there is no
> str↔pr split to design here, unlike regex/uuid/ns/bigint which `writeStrValue`
> special-cases. clj also renders them identically (both the `#object[…]` form),
> so unified is the correct target. The `Function` struct (`tree_walk.zig:130-167`)
> carries `name`/`defining_ns` as `?[]const u8`, both static analyzer-arena slices
> (GC-inert). The `context_provider` precedent (`info.zig:122-141`) is a
> file-private `var ?*const fn() ?Value` + `setContextProvider`, installed from a
> higher layer — exactly the inversion shape the draft mirrors. `tag_ops`
> (`gc/tag_ops.zig`) already holds three `pub var [64]?fn` tables registered via
> `registerTrace`/`registerFinaliser` from `driver.installVTable` →
> `tree_walk.registerGcHooks` (`driver.zig:107-125`). These are the two
> zone-crossing vehicles in play.
>
> None of the three alternatives requires violating an F-NNN. The
> finished-form-clean option (Alt 2) is fully expressible within AD-002 +
> ADR-0059 + zone_deps.
>
> **Alt 1 — smallest-diff: file-private accessor + `#<ns/name>` (≈ the current
> draft, minus co-design)**
>
> A file-private `var fn_name_accessor: ?*const fn(Value) FnIdentity = null;` +
> `setFnNameAccessor` in print.zig (or a tiny `runtime/fn_identity.zig` helper),
> installed from `driver.installVTable` alongside `registerGcHooks`. Add one
> `.fn_val` arm to `printValue`: call the accessor, format `#<user/boom>` (named)
> / `#<fn>` (anonymous). `writeStrValue` inherits it via its `else`→`printValue`
> fall-through (no second edit). Record AD-025. Leave `multi_fn`/`protocol_fn`/
> `builtin_fn` and `(class fn)` out.
>
> - **(a) Better than the draft:** essentially *is* the draft, so nothing —
>   except it is the honest floor: one arm, one accessor, one AD row, smallest
>   surface to get wrong. Reuses the exact, already-blessed `context_provider`
>   injection idiom (not a new mechanism the reader must learn). `FnIdentity` (a
>   `struct { ns: ?[]const u8, name: ?[]const u8 }`) is value-returning, so no
>   lifetime/GC question crosses the zone — the slices are analyzer-arena-static
>   and only read for immediate formatting.
> - **(b) Breaks/risks:** It is *one of N callable tags*. `multi_fn` (`defmulti`)
>   and `protocol_fn` are sibling user-named callables that will keep printing
>   `#<multi_fn>` / `#<protocol_fn>` — leaking the internal tag name, the
>   **exact** bug D-328 names, for two tags out of four. Shipping a
>   `.fn_val`-only arm is a half-swept area (the Micro-coverage-grind /
>   partial-sweep smell in `clj_diff_sweep.md` Discipline 2): the debt ledger
>   reads "fn print: done" while `defmulti`/protocol fns still leak. A second
>   risk: a *single file-private accessor for fn_val only* invites a third and
>   fourth accessor when multi_fn/protocol_fn get the same treatment — three
>   near-identical file-private `var`+setter triples, which is the
>   Reservation-as-bias / smallest-diff accretion the project warns against. The
>   print form `#<user/boom>` is defensible but under-specified vs clj: see the
>   form discussion in the recommendation.
>
> **Alt 2 — finished-form-clean: a `tag_ops`-registered print descriptor for the
> whole callable family, name carried in a runtime-readable place**
>
> Two moves, both at the finished-form altitude:
>
> 1. **Mechanism = extend `tag_ops` with a per-tag *display* hook**, not a fourth
>    bespoke accessor. `tag_ops` is *already* the Layer-0 registry the eval layer
>    injects per-tag behaviour into (`registerTrace`/`registerFinaliser` from
>    `driver.installVTable`). Add a `tag_display_table: [64]?DisplayFn` +
>    `registerDisplay`, where `DisplayFn = *const fn(Value, *Writer)
>    Writer.Error!void` (or returns a small `FnIdentity` the print site formats,
>    to keep the `#<…>` envelope policy in *one* place — print.zig — rather than
>    scattered into eval). `printValue`'s `else` arm consults
>    `tag_display_table[tag]` before falling to `#<tag>`. `tree_walk.registerGcHooks`
>    (already the install point) registers display fns for `.fn_val`, `.multi_fn`,
>    `.protocol_fn` in one place. This generalises the zone-crossing to *any* heap
>    tag whose pretty-name lives above Layer 0 — which is the same shape
>    `.ns`/`.host_instance`/`.typed_instance` already needed and got via ad-hoc
>    routes. The reader who knows `registerTrace` instantly knows `registerDisplay`;
>    no new idiom.
> 2. **Form = decide the *callable* print envelope once, for all four callable
>    tags coherently.** Named user callable (`fn`/`defmulti`/`defn`-protocol-method)
>    → `#<ns/name>`; anonymous → `#<fn>` (or `#<fn--N>` if a gensym id is cheaply
>    available); builtin (no name slot, D-327) → keep `#builtin` *or* upgrade to
>    `#<builtin/name>` once D-327 lands a name. The AD row (AD-025) covers the
>    whole family with one `derives_from: AD-002 + AD-003 + ADR-0059`, one pin test
>    exercising fn + defmulti + protocol-fn + anon + builtin.
>
> - **(a) Better than the draft:** Closes the *entire* callable-print leak in one
>   push, satisfying `clj_diff_sweep.md` Discipline 2 (big-bang, don't drip-feed)
>   — no "multi_fn still leaks" residue, no second/third cycle re-deriving the same
>   accessor. Mechanism is the project's *own* established generalisation
>   (`tag_ops`), so it removes the temptation to grow N file-private accessors; the
>   next opaque-tag pretty-name (a future `wasm_fn`, etc.) drops into the same
>   table for free. Puts the `#<…>` envelope policy in exactly one site
>   (print.zig), honouring error_catalog-style "one message source" hygiene for
>   print forms. One AD row instead of three.
> - **(b) Breaks/risks:** Larger blast radius — a new `pub var` table in
>   `tag_ops.zig` (note: `tag_ops` already uses `pub var` tables, so this is
>   *consistent with existing precedent*, not a §13 `pub var` *vtable* violation —
>   the §13 ban is on `pub var` **VTable structs**, and these all-null-default
>   per-tag arrays are the sanctioned shape per ADR-0028 §4). Risk:
>   over-generalising before a second consumer exists could read as speculative
>   (YAGNI) — but there are already *three* immediate consumers
>   (fn/multi_fn/protocol_fn) plus the `.ns`/`.host_instance` ad-hoc arms that
>   retroactively fit, so the second-consumer test is already met; this is not
>   speculative. Touching `multi_fn`/`protocol_fn` formatting risks a
>   differential-test ripple (their current `#<multi_fn>` strings may be asserted
>   somewhere) — a grep + diff-corpus pass is needed, which is correct work, not a
>   reason to shrink. The `DisplayFn`-returns-Writer variant lets eval write
>   directly into the print buffer, which slightly muddies "print policy lives in
>   Layer 0"; the `FnIdentity`-returning variant is cleaner and recommended.
>
> **Alt 3 — wildcard: drop the zone-crossing entirely by giving the print form
> what it needs at the Value level — a name slot reachable from Layer 0**
>
> Instead of injecting a function pointer from eval, make the identity **readable
> from Layer 0 directly**. Two sub-shapes:
>
> - **3a (header-resident name):** move `name`/`defining_ns` out of the Layer-1
>   `Function` struct into a Layer-0-visible prefix — e.g. a small
>   `runtime/callable_header.zig` struct that `Function` (and `MultiFn`/`ProtocolFn`)
>   embed right after `HeapHeader`, at a fixed offset Layer 0 can decode without
>   importing eval. print.zig reads `callable_header.nameOf(v)` with no accessor,
>   no setter, no install step. The zone rule is satisfied because the *struct
>   lives in Layer 0* and eval merely fills it.
> - **3b (name as interned symbol Value in the header):** stash the qualified name
>   as an already-existing `.symbol` Value (a Layer-0 type) in a header slot; print
>   just `printValue`s that symbol inside `#<…>`. Reuses symbol printing verbatim.
>
> - **(a) Better than the draft:** *No injection mechanism at all* — no
>   file-private `var`, no setter, no startup-order dependency, no "is the accessor
>   installed yet?" failure mode (the draft's accessor is null until `installVTable`
>   runs; a print before that prints `#<fn_val>` again — a real ordering footgun
>   3a/3b eliminate). The name becomes a first-class property of the callable
>   Value, which is arguably where it *should* live (clj's fn name is intrinsic to
>   the object, not injected). 3b reuses symbol printing for free and round-trips
>   naturally.
> - **(b) Breaks/risks:** Biggest structural surgery — moving `name`/`defining_ns`
>   into a Layer-0 header touches the `Function` layout (which has a load-bearing
>   `comptime` offset assert at `tree_walk.zig:164-166` and a GC-rooting note), the
>   VM `op_make_fn` closure reconstruct (`tree_walk.zig:160` notes name is copied
>   there too), and every alloc site. 3b additionally makes the name a GC-managed
>   `.symbol` Value, which means `traceFunction` must mark it (currently name is
>   GC-inert static `[]const u8` — a deliberate property the struct comment calls
>   out); that *adds* a rooting obligation the current design specifically avoids.
>   This is depth-4 surgery for a print-form fix — likely disproportionate *now*,
>   but it is the genuinely different angle: it treats "Layer 0 can't see the name"
>   as the root problem to dissolve rather than to bridge. Defensible as the
>   finished-finished form if a future Phase already needs callable identity in
>   Layer 0 (e.g. `class`/`type` of a fn, demunging, AOT name tables) — otherwise
>   premature.
>
> **On the three sub-questions the brief flags:**
>
> - **(i) Print form:** `#<user/boom>` is the right envelope — it is AD-002's
>   established `#<tag>` shape with the tag *replaced by the qualified name*, which
>   is strictly more informative and still drops clj's non-reproducible
>   `#object[user$boom__N 0xHASH …]` identity-hash+munged-class per
>   AD-002/AD-003/ADR-0059. Do **not** mimic `#object[…]` (it implies a JVM class +
>   would re-invent the munged `user$boom__7` name AD-003 exists to avoid).
>   Anonymous → `#<fn>` is coherent. `builtin_fn` (no name, D-327) should *not* be
>   forced into this cycle — `#builtin` stays until D-327 gives it a name slot; but
>   the *form* should be chosen now so D-327 just fills the name
>   (`#<clojure.core/map>`-style), i.e. co-design the *envelope*, defer the *data*.
>   `str` vs `pr` must **not** differ (verified: both reach the same site; clj
>   agrees) — this is a feature, not a gap, and the AD row should state it
>   explicitly so a future sweep doesn't "fix" them apart.
> - **(ii) Mechanism:** `tag_ops`-registered display (Alt 2) over a bespoke
>   file-private accessor (Alt 1) — it is the *existing* Layer-0↔Layer-1 injection
>   registry, already installed at exactly the right startup point, and it scales
>   to multi_fn/protocol_fn without a second/third accessor. Threading `*Runtime`
>   through `printValue` is the worst option (touches every print call site, and
>   `printValue` is deliberately a free function — a large ripple for no benefit,
>   smallest-diff-*negative*). Moving the name into a Layer-0 header (Alt 3) is the
>   cleanest *eventual* shape but disproportionate surgery now.
> - **(iii) `(class fn)`:** correctly **deferred**. `(class x)` returns a
>   TypeDescriptor simple name (AD-003); fn's class story is a *type-system*
>   concern (what TypeDescriptor does a closure carry?), not a *print* concern, and
>   co-designing it now would drag TypeDescriptor design into a print-form cycle.
>   Defer with its own debt row + a one-line note in AD-025 that the print form
>   does not imply a class decision.
>
> **Non-binding recommendation.** The finished-form-cleanest shape is **Alt 2 with
> Alt 1's `#<ns/name>` form decision** — i.e. *not* the bespoke file-private
> accessor, but a `tag_ops`-registered per-tag display hook covering the whole
> callable family (`fn_val`, `multi_fn`, `protocol_fn`) in one big-bang push, with
> the `#<ns/name>` / `#<fn>` envelope and a single AD-025 row + multi-tag pin test.
> The draft's accessor (Alt 1) is finished-form-*adjacent* but trips two project
> smells: it leaves `multi_fn`/`protocol_fn` leaking the raw tag name
> (partial-sweep, `clj_diff_sweep.md` Discipline 2) and it seeds a family of
> near-identical file-private accessors instead of using the `tag_ops` registry the
> project *already* built for exactly this Layer-0↔Layer-1 inversion. Per F-002,
> the slightly larger diff of generalising into `tag_ops` is not a reason to prefer
> the accessor — and crucially the generalisation has three immediate consumers, so
> it is not speculative. Alt 3 (Layer-0 header-resident name) is the genuinely-final
> form and worth a one-line forward-pointer in the ADR, but its depth-4 layout
> surgery (offset assert, VM reconstruct, and — for 3b — a *new* GC-rooting
> obligation on what is today a deliberately GC-inert name) is disproportionate for
> a print-form fix; defer it to whenever a non-print consumer (fn `class`/AOT name
> tables) first needs callable identity in Layer 0. `(class fn)` stays out of scope
> with its own debt row.

### Main-loop response to the DA (why the mechanism diverges from the recommendation)

The DA's big-bang FORM insight is **adopted** — all three callable tags land
`#<ns/name>` in this one push; no partial sweep. Its *mechanism* recommendation
(a `tag_ops` display table) rests on a premise the main loop verified false:
`MultiFn` (`runtime/multimethod.zig:55`) and `ProtocolFn` (`runtime/protocol.zig`)
are **Layer-0 `extern struct`s** that `print.zig` reads directly — only `.fn_val`
crosses a zone. So the table would have a **single registrant**, making it the
speculative-generality the DA's own Alt 2 risk (b) flags ("over-generalising
before a second consumer exists"). With one cross-zone consumer, the bespoke
`context_provider`-style accessor IS the proportionate finished form and seeds no
accessor family. This is not a cycle-budget downgrade (F-002) — it is the
finished-form choice once the consumer count is corrected from 3 to 1.

## Consequences

- `(pr fn)` / `(str (defmulti …))` / `(pr protocol-fn)` render `#<ns/name>`
  instead of the internal tag name. The latent `#<multi_fn>`/`#<protocol_fn>`
  leaks close in the same push.
- `print.zig` gains a `fn_name_accessor` (one setter-injected fn pointer, mirroring
  `context_provider`) + a `printCallable` helper; `tree_walk.registerGcHooks`
  installs the accessor.
- AD-025 records the clj `#object[…]` divergence with a pin test.
- `(class fn)` unchanged (deferred). Builtins unchanged (`#builtin`, D-327).

## Affected files

print.zig (FnIdentity + setFnNameAccessor + printCallable + 3 switch arms +
fallback-test retarget + new tests), tree_walk.zig (fnIdentity accessor +
registerGcHooks install), .dev/accepted_divergences.yaml (AD-025), e2e +
diff_test (print forms, both backends), .dev/debt.yaml (D-328 discharge).
