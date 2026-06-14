# Sweep plan — confirmed order (2026-06-14, user-directed)

> The SSOT for the current **sweep + wasm-north-star phase**. `/continue` reads
> this after `handover.md` to pick the next unit autonomously. Order is
> top-to-bottom; finish a unit, commit LOCALLY, move to the next.

## Phase mode (READ FIRST — overrides standing rules this phase)

- **LOCAL accumulation, NO push.** Commit each unit locally; do NOT `git push`.
  The post-commit / gate "push immediately" reminders do NOT apply this phase.
  (User 2026-06-14: 「スイープサイクルはpushなしでローカルに累積でいいよ」.)
  SSOT: memory `local-accumulation-sweep-phase`.
- **wasm uses the RELATIVE-path zon** (`.zwasm = .{ .path = "../zwasm_from_scratch" }`),
  push-forbidden, because zwasm is not yet re-pinned with REQ-7. The local zwasm
  checkout HEAD contains REQ-7 (33e0100c) so `-Dwasm` works. Do NOT flip to a git
  pin until the user re-pins. (User: 「まだpinしてません。相対パスでやるしかない」.)
- Per-commit gate = smoke (default build unaffected — zwasm dep is `lazy` +
  `-Dwasm`-guarded). wasm-touching work additionally runs `-Dwasm` build/probe.
- Phase ENDS when the user re-pins zwasm (then rebase onto the pin + push) or says push.

## Order

### Track D — divergence-burden remediation (user-directed 2026-06-14; ordered by readiness)

The user asked to address ALL of the post-Track-C "intentional clj-divergence"
burden items #1–#5 from the 2026-06-14 chat audit, and to wire them so `/continue`
acts concretely. **The audit corrected the list**: #2 and #5 were ALREADY RESOLVED
and #4 is GATED; the actionable, ease-ordered queue is **D1 → D2 → D3**.

- **D1 — seq-as-map-KEY content hash (D-432 + D-408). ✅ DONE 2026-06-14 (ADR-0139,
  Option A + Alt-1).** rt-aware `hashDispatch`/`eqConsult` via the ADR-0129
  `current_env`; `runEnvelope` armed (Alt-1, closed an AOT silent-miss the DA fork
  found). Corpus `seq_key_hash.txt` (10) + e2e `phase14_seq_key_hash.sh` (7). Nested
  + rt-free-memoized finished form deferred → **D-437** (standalone quality-loop,
  NOT Phase-gated). **Resume → D2.** Original entry below.
  Bug: a content-equal `lazy_seq` / `cons` / `range` / Sequential-deftype used as a
  map/set KEY hashes by IDENTITY → `(get {(map inc [0 1 2]) :x} '(1 2 3))` silently
  `nil` (clj `:x`). `=` already content-matches; only the key-HASH diverges.
  **Chosen shape = Option A** (survey done): make the key path rt-aware via the
  EXISTING `dispatch_mod.current_env` ambient threadlocal (ADR-0129) — realize
  lazy/range/Sequential-instance keys, then delegate to `seqHash`/`seqKeyEq`.
  ~1 file, **NO signature change**. Why it's clean now: the "key-hash must be
  rt-free" premise is ALREADY broken by ADR-0129 — temporising it further is the
  Reservation-as-bias the audit flagged as the **#1 finished-form win**.
  Reads: `private/notes/p14-seq-key-hash-survey.md` · `src/runtime/collection/map.zig`
  (`keyHash`:190 + its callers) · `src/runtime/equal.zig` (`hashConsult`/`current_env`,
  `SeqKeyCursor`:119, `seqHash`:654, `isSequential`:67) · `src/runtime/hash.zig`
  (`hashOrdered`:102) · ADR-0129 · debt D-432/D-408 · F-011.
  First red: e2e `(get {(map inc [0 1 2]) :x} '(1 2 3))` → `:x` (+ cons-over-lazy +
  range + a Sequential deftype key + a `clj_corpus/seq_key_hash.txt` corpus).
  Residual to cover: the nested map-as-key case (`foldHash`/`entryHash` rt-free path).

- **D2 — caught-exception cljw frame-seq accessor (D-232 / AD-029). post-M, moderate.**
  `clojure.stacktrace/print-stack-trace` degrades to `[no stack trace available]`; the
  ExInfo DOES carry frame data (`trace_ptr`, ADR-0120) but exposes no Clojure-level
  accessor. Expose a cljw-SHAPED frame seq (NOT JVM `StackTraceElement` — AD-024
  user-only stays) wired into `clojure.repl`/`clojure.stacktrace`; flip the AD-029 pin
  when frames appear. Reads: AD-029 + AD-024 + ADR-0120 (`trace_ptr`) + debt D-232 +
  `src/runtime/error/`.

- **D3 — `:volatile-mutable` cross-thread visibility (AD-018). GATED on Phase 15 concurrency.**
  D-288 / ADR-0104 landed the mutable-field MECHANISM; the volatile-vs-unsynchronized
  VISIBILITY distinction is dormant-by-design (single-thread). When Phase 15 concurrency
  lands, route `:volatile-mutable` through an atomic store. Reads: AD-018 + D-288 +
  ADR-0104 + the Phase 15 concurrency ADR. **Do NOT start before Phase 15 concurrency exists.**

- **RESOLVED by the 2026-06-14 audit (do NOT re-chase):**
  - **#2 `+'`/`*'` promoting family** — DONE (D-260 / ADR-0100; `(+' Long/MAX 1)` → `…808N`).
    The kept divergence is AD-008 (`+` promotes where clj throws — user-ratified). AD-008's
    "tracked in D-211" text is stale (D-211/D-260 discharged); no work remains.
  - **#5 VM-as-shipped-default** — DONE (D-196 discharged; `build.zig:52` `orelse .vm`).
    F-012's "flip is gated" wording is stale future-tense (F-NNN is user-owned; left as-is).

### Track C — `*out*`/`*in*` cljw-native writer/reader value (DONE 2026-06-14, ADR-0138 steps 1-3)
The user chose recommended **Option C** (see handover § *out*/*in* design + D-436(b)).
- **C1 (ADR + DA fork):** a single cljw-native writer value + reader value
  (NOT a java.io.Writer/Reader hierarchy clone). `*out*`/`*err*`/`*in*` bind to
  instances. Clojure-observable interop surface only: `.write`/`.append`/`.flush`/
  `.close` (writer) + `read`/`read-char`/`unread-char`/`peek-char`/`read-line`
  (reader) dispatch on it; print/read-line/with-out-str/with-in-str keep working.
  cljw 流儀: UTF-8 fixed, no charset/PrintWriter/BufferedWriter hierarchy.
- **C2 (impl):** the value type(s) + binding + interop dispatch; `with-out-str` =
  rebind `*out*` to a string-backed writer value (kills the `out_capture`
  threadlocal cross-zone hack). REMOVE the sentinel special-casing
  (`out_writer_method.zig`, D-434) once the value path subsumes it. *in* absorbs
  the D-414 LispReader$StringReader shims into one reader value.
- Discharges: D-436(b); supersedes D-434's sentinel routing; folds D-414 reader shims.

### 2. Track S — honest debt sweep (highest-value-first; see handover § debt map)
- **S1 — debt-hygiene 棚卸し (quick, do early):** fold the DONE/VERIFIED-in-place
  `active:` rows into `discharged:` (D-366 license [done by clj_attribution rule],
  D-362 CFP demo, D-331 cross-module trace, D-250 torture, the Phase-reserve /
  opportunistic rows). Drives D-243 + D-436(H). Shrinks 149→~real count.
- **S2 — clj-parity bugs:** D-432 + D-408 (lazy/seq-as-map-KEY hashes by identity),
  D-271 (with-meta on range), D-270 (primitive arrays int-array/…), D-374
  (top-level `do` not unrolled), D-228 (nested syntax-quote), D-220 (stateful regex
  matcher), D-223 (atom kwargs), D-389 (ex-data shape PARTIAL). Plus D-433 (exception
  str/pr one-liner) — folds into Track C's writer model if convenient.
- **S3 — Java surface (D-425/D-431 continue):** BUILD the over-claimed unbuilt
  classes then corpus them — java.time family (Instant/Duration/LocalDateTime/
  ZonedDateTime, D-105/D-243), java.math.BigDecimal, java.util.Arrays; then the
  lib blockers D-430 (instaparse GLL), D-410 (BreakIterator→cuerdas), D-360
  (data.json :key-fn), D-376 (Murmur3). ADR-0137 sharpening: generate compat_tiers
  `methods:` from the corpus (kills the over/under-claim).
- **S4 — error display overhaul:** D-323 (v0-level error display; CFP target) +
  D-326/327 (builtin/interop frames), D-337 (`(class fn)`).
- **S5 — perf (§9.2.S):** D-386 (per-instruction dispatch = fib/tak lever),
  D-320 (regex lookahead), D-266 (lazy-seq element cost), D-381, D-364 (bench
  ReleaseSafe honesty).
- **S6 — validation campaign:** D-232 (upstream clojure.test suites + clojuredocs
  differential — finds new cljw↔clj bugs at scale).
- **S7 — the rest** at value / Phase: polymorphism (D-369/314/319), runtime
  (D-305/254/255/241/239/310), security + Phase-16 (D-338-354/347/350) — mostly
  forward-looking, take at their Phase.

### 3. Track W — wasm north-star (F-014.4 differentiator; interleave with C/S)
- **W0 — instance-caching re-land: DONE 2026-06-14** (un-stashed; relative zon;
  `(wasm/load-component p)` + `(wasm/component-call h …)`; greet roundtrip +
  resource chain validated). Local commit only.
- **W1 — require-a-component (export = a Clojure Var). FULL DESIGN below.**
- **W2+:** the Phase 15-20 Wasm/edge surface (components as the deploy unit, edge
  runtime). The reason cljw exists over the JVM. North star = **deps.edn
  `{:wasm/component …}` coords** so `(:require [acme.greeter])` resolves + loads a
  component, making components distributable/versioned units.

#### W1 design — require-a-component (user-confirmed 2026-06-14)

**Vision (the 書き味 target):** a component's exports become callable Vars in a
namespace, indistinguishable from normal Clojure fns, with `doc`/`arglists` from
the WIT. The user proposed this long ago; this is its concretisation.

**Usage vibe (target surface):**
```clojure
(require '[cljw.wasm :as w])
(w/require-component "greet.wasm" :as greeter)   ; explicit form (honest, no magic)
(greeter/greet "world")            ; => "Hello, world!"  — just a fn
(doc greeter/greet)                ; greet([name :string]) -> :string  (from WIT)
(w/require-component "greet.wasm" :refer [greet]) (greet "world")  ; refer form
;; resource (stateful) — ctor reads as factory, method as handle-fn:
(w/require-component "counter.wasm" :as ctr)
(with-open [c (ctr/counter 5)] (ctr/increment c) (ctr/get c))     ; => 6
;; ultimate (needs W2 deps.edn): (ns my.app (:require [acme.greeter :as g]))
```

**WIT ↔ EDN marshalling (the core; pin as a table + corpus):**
record↔map(kw keys) · variant↔`[:tag payload]` (no-payload → bare kw) · enum↔kw ·
option↔nilable · result↔value on ok / `ex-info` throw on err (opt `:result :tagged`
→ `[:ok v]`/`[:err e]`) · list↔vector · tuple↔vector · flags↔`#{kw}`. string/
ints/floats/bool/char already marshal (component-invoke today). The existing
`component-exports` already returns `{:name :params :result}` maps — params/result
are WIT type STRINGS (`"string"`, `"u32"`, `"own<21>"`); the marshaller maps those.

**Name cleanup (require layer's #1 job):** strip the raw WIT export name to a clean
Clojure symbol: `pkg:iface/…#[constructor]counter` → `counter`;
`…#[method]counter.get` → `get`; `…#[method]counter.increment` → `increment`; a
plain `greet` stays `greet`. (Collision policy: if two ifaces export the same short
name, fall back to `iface/name` or require `:as`.)

**Resources:** an opaque handle Value (the `own<N>` from a ctor) + `Closeable`
(`with-open` → `dropResource`, D-325) + GC-finaliser drop. Methods take the handle
as first arg → `(ctr/increment c)`. Do NOT fake immutability — cljw 流儀 = "thread
a Closeable handle through" (honest about WIT's stateful resource model).

**Vars:** one builtin-fn Var per export, interned into a synthetic ns (`:as`) or
the current ns (`:refer`), closing over the cached `Opened` handle (from
`load-component`). Each Var carries `:arglists` (from params) + `:doc`/`:wit/sig`
(from the WIT signature) → `(doc …)` shows the signature = the "reads at a glance"
payoff.

**Implementation order:** (a) name cleanup + the WIT↔EDN marshalling table (+ a
class_corpus-style golden corpus of round-trips) → (b) `require-component`/
`import-component` that interns one Var per export closing over the handle, with
WIT metadata → (c) resources: handle value + Closeable + GC-drop (D-325) → (d) W2
deps.edn `{:wasm/component …}` coord resolution.

**Step-0 investigation targets (start here):** how zwasm surfaces WIT param/result
types via `resolveFuncSig`/`WitType` (read `component.zig` invokeOnOpened + the
zwasm CM-API); the existing `marshal.zig` (what value mapping already exists); how
cljw interns a synthetic ns + Vars at runtime (env.intern + a namespace value);
closure-over-handle for a builtin-fn Var; the result→throw-vs-tagged decision (DA);
the deps.edn component-coord shape (cf. the existing `:git/url` resolver, D-274).
ADR this (W1 is load-bearing surface design; DA fork). [D-404 / ADR-0135]

### 4. Ongoing — D-436 大整理 (finished-form deviation epic)
Drain candidates as Track C/S touch them: D-435 (diff-oracle full-runtime gap —
bootstrapping/cached Fixture so dual-backend verifies full-runtime forms),
*out*-sentinel (→ Track C), compat_tiers generated index (→ S3), bundled-lib
moot-coord. Add a candidate the moment a workaround-instead-of-finished-form is taken.

## Reference chain (audit 2026-06-14, re-audited at the Track D wiring)
handover.md → THIS file → `.dev/debt.yaml` (Track D: D-432/D-408 [D1], D-232 [D2],
AD-018/D-288 [D3]; + D-431..D-436 cluster) → `private/notes/p14-seq-key-hash-survey.md`
(D1 survey) + `.dev/accepted_divergences.yaml` (AD-008/018/024/029 — the kept/gated
divergences the audit classified) + `.dev/decisions/0137_scope_goal_line.md`
(F-014/ADR-0137) + memories `local-accumulation-sweep-phase` +
`finished-form-no-workaround-accumulate`. Verified at wiring: every Track D debt ID
resolves (`check_debt_id_refs` ok); D1 is the only READY item (DO FIRST).
