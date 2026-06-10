# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-373 instance?-as-fn + ADR-0128 + the gate-cadence
  scaffolding reconciliation, all pushed). Gate cadence (now the documented
  default everywhere — ADR-0107): per-commit **smoke**
  (`bash test/run_all.sh --smoke <step>`, background it, don't block); **batch the
  full gate** at the ≤5 ceiling / Phase boundary / pre-tag; verify manual probes on
  a **ReleaseSafe** binary (`zig build -Doptimize=ReleaseSafe -Dcpu=baseline`).
- **First on resume MUST be: HONOR THE FREEZE** — do **not** self-select the next
  unit; wait for an explicit human go (the standing directive in § Stopped). The
  loop's usual self-select rule is suspended until the human lifts it.
- **When the human gives go**, the highest-value next unit is **D-375**
  (`APersistentMap/mapHash` + the clojure.lang abstract-collection static hash
  helpers — flatland.ordered.map's LIVE next blocker at map.clj:123, and a gap the
  D-372 data-structure cluster shares). Second: **D-374** (top-level-`do` unroll,
  clj-parity, eval-semantics). Both are filed with full barriers.
- **Forbidden**: pushing to `main`. The fly demos (D-362) are DONE + live.

## Just landed

- **D-373 / ADR-0128 — `instance?` is a fn over a class VALUE** (finished form,
  user-directed; DA-fork depth-3 verbatim in the ADR, adopted Alt 2'). Dropped the
  `expandInstanceQ` macro → `(def instance? (fn* [c x] (rt/-instance-of? c x)))`, so
  higher-order use works (condp/map/partial/apply/bound-fn-arg). Completed
  `class_name.isInstance` into a no-special-case membership oracle (widened
  NUMBER_TAGS to the full tower == `number?`; one-line Object arm; opaque → false
  naturally), so `-instance-of?` has zero taxonomy branch. ONE
  `classValueKeyFor`-driven `classDescriptor` analyzer arm replaced the scattered
  exception/opaque/Object/Number/IFn/host_inert arms (interface markers now resolve
  as values; arm consults ns.imports). Renamed `exceptionDescriptor`→`classDescriptor`
  (D-293 unify). `Map$Entry`→`MapEntry` in FQCN_MAP. clj-oracle bit-for-bit; corpus
  2252/2252 + e2e phase7 Case 8/9 + corpus instance_higher_order.txt. **ordered.map
  advanced PAST the entire instance?/Map$Entry surface (map.clj:59) to its next,
  DIFFERENT blocker `(APersistentMap/mapHash …)` at :123 (D-375).**
- **Gate-cadence scaffolding reconciled to ADR-0107** (user-directed): the stale
  "run the full gate every commit" wording (a light-e2e-era artifact) is replaced by
  the smoke-per-commit / batch-full model across CLAUDE.md (L125 + Step 5 + Build&test),
  `gate_cadence.md` (SSOT — retired the additive-vs-risky table; smoke authorises
  shared-code too), continue SKILL resume step 6, exploration_vs_done.

## Follow-ups tracked

D-375 (clojure.lang static hash helpers — ordered.map live blocker) · D-374
(top-level-do unroll) · D-369 (transient dispatch) · D-238 (bindable `*out*`) ·
D-276 (class-value markers residual). quality_floor rows = the standing
correctness-first drain. `private/notes/D373-instance-of-fn.md` = this unit's note.

## Cold-start reading order

handover → `.dev/debt.yaml` D-375 + D-374 (the named next units) →
`.dev/decisions/0128_instance_of_fn_class_value_surface.md` → CLAUDE.md
§ Autonomous Workflow.

## Stopped — user requested

User instruction (2026-06-10, verbatim): 「クリアセッションから続行 D-373 を
finished-form で続けて、そこでしばらく freeze（人間が明示するまで進めない）という予定で、
配線・参照チェーンを監査して止めてください。」
→ D-373 LANDED this session (ADR-0128, finished form). Per the directive the loop is
now **frozen**: do not self-select the next unit; wait for an explicit human go. This
is a STANDING directive that persists across sessions until the human lifts it (not a
single-session stop) — when go is given, start D-375 (see Resume contract).
</content>
