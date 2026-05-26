# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Operating mode (user directive 2026-05-27)

完全自律で進める。`[x]` flip / feature_deps status flip / ADR
"Selected:" 確定 / DA subagent の "Recommendation" 採用 等の
framework boundary では **pause + PushNotification しない**。
CLAUDE.md § The only stop の "only user explicit stop halts the
loop" を operative rule として運用し、autonomous-tick framing の
"Reaching for justifications, wait" heuristic は採らない。row /
ADR / cycle 境界はそのまま次の Step 0 survey に roll する。

## Resume contract

- **HEAD**: see `git log` (row 7.13 close is HEAD).
- **First commit on resume MUST be**: §9.9 row 7.14 — Step 0
  survey for the Phase 7 exit smoke. Per ROADMAP §9.9, row 7.14
  is "Phase 7 exit smoke — e2e: defprotocol / extend-type / .method
  + defmulti / defmethod / prefer-method dispatch". All component
  cycles landed (rows 7.1..7.13); row 7.14 adds the explicit
  exit-smoke shell e2e + verifies existing phase7_*.sh suite
  covers each criterion bullet. Reference: ROADMAP §9.9 row 7.14
  + Exit criterion text.
- **Forbidden this session**: (a) `return error.NotImplemented` in
  VM compile arms without `// VM-DEFER:` marker. (b) direct
  `TypeDescriptor.lookupMethod` — route via `dispatch(...)`.
  (c) widening `BytecodeChunk.call_sites` / `.libspecs` beyond
  ADR-0040 / row 7.10 cycle 3. (d) manual `defer rt.gc.infra.
  destroy(...)` for ProtocolDescriptor / ProtocolFn /
  TypeDescriptorRef — row 7.7 cycle 1 `rt.trackHeap` owns destroy.
  (e) accessing dropped flat `FnNode.arity/.has_rest/.params/.body`.
  (f) cw v0 threadlocal `apply_rest_is_seq` — row 7.9 ADR-0042
  diverges. (g) widening `isRestSeqShaped` tag set without
  ADR-0042 amendment. (h) cw v0 `pub var exception_matches_class`
  injection — row 7.11/7.12 diverge; `host_class.matches` /
  `class_name.isInstance` directly imported Layer 1 → Layer 0;
  widening `ENTRIES` requires co-issued `compat_tiers.yaml` +
  diff_test in same commit. (i) cw v0 vector-with-metadata
  zipper shape — row 7.13 ADR-0043 diverges; `(defrecord ZipLoc
  ...)` is permanent finished form even after D-075 lands. (j)
  using `(and ...)` macro in `.clj` defns inside non-core
  namespaces — zip.clj cycle 1 surfaced a bug; use explicit `if`
  until the macro is audited.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.9 → `.dev/debt.md`
Step 0.5 sweep (row 7.14 has no specific debt; D-093/D-094
opportunistic carry-overs).

## Current state

Phase 7 IN-PROGRESS — §9.9 rows 7.0..7.13 all [x]. Row 7.14 next.
Branch `cw-from-scratch`. Gate green at HEAD: Mac 57/57 + OrbStack
Ubuntu x86_64 56/56.

## Active task — §9.9 row 7.14

Phase 7 exit smoke. Per ROADMAP §9.9 exit criterion: defprotocol /
extend-type / `.method` dispatch e2e + defmulti / defmethod /
prefer-method ladder + transducer fused path bench (likely
deferred to Phase 8) + defrecord + reify + multi-arity fn*
end-to-end. All component cycles are landed (rows 7.1..7.13);
row 7.14 just adds the explicit exit-smoke shell e2e + verifies
the existing phase7_*.sh suite covers each criterion bullet.

## Open questions / blockers

None testable from inside the loop. Outstanding debt by ID:
D-081 (multimethod ergonomic surface; blocked-by D-012 Phase 15),
D-083 / D-085 / D-086 / D-087 / D-088 (opportunistic Phase 7+
follow-ups; D-085 keyword-as-fn would simplify xml-zip; D-086
defrecord `__extmap` would simplify `with-loc-internal`; D-091
`^:private` metadata would un-block annotation in zip.clj
internals), D-089 (row 7.7 retro-audit cluster, Phase 8+),
D-090 / D-092 (Phase 8+ Map / recur cleanups), D-093 (regex
`$N` capture-group sugar — D-051 cycle 3), D-094 (clojure.string/
escape Pattern A migration). D-048 host-class wire-up unblocks
shared `host_instance` arm in host_class + class_name.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`.
Landmarks rows 7.2-7.13: ADR-0008 amends, 0039, 0040, 0041
(multi-arity fn*), 0042 (apply variadic peel-and-pass), row 7.10
(ADR-0036 first real-feature exercise), row 7.11 (host_class +
analyzer-time catch_class_unknown), row 7.12 (instance? +
class_name + replace Pattern A), row 7.13 (ADR-0043 — defrecord
ZipLoc + 31 zipper vars; cw v0 vector-with-metadata + JVM-faithful
path rejected per F-003 D-075 hard-block).
