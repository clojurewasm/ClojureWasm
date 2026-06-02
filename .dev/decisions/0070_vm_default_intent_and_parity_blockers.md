# ADR-0070 — VM is the intended production default (§349); flip gated on the parity blockers (D-196)

- **Status**: Proposed → Accepted (2026-06-02)
- **Records**: ROADMAP §349 ("default is VM after Phase 4") + build.zig 4.8
  comment ("4.12 flips the default once differential parity is green") were the
  ORIGINAL plan; the flip was **never executed** (drift). This ADR makes the
  intent + the concrete blocker list explicit, and establishes F-012.
- **Corrects drift in**: ADR-0050/0056/0036, which narrated `tree_walk` as "the
  production-default backend" — calcifying the un-flipped interim state as if
  intended. No ADR ever *decided* to override §349.
- **Related**: ADR-0005 (dual-backend oracle), F-002, F-010, F-011, F-012 (new),
  D-196 (the parity blocker cluster). Surfaced 2026-06-02 by the user.

## Context

§349 always intended VM as the default after Phase 4; tree_walk is the
differential oracle. 4.8 made tree_walk a **temporary** default "until 4.12
confirms parity"; 4.12 [x] confirmed Phase-4 smoke parity — but `build.zig`
kept `orelse .tree_walk` and the flip never happened.

A 2026-06-02 experiment flipped `build.zig` to `vm` and ran the full gate. The
clj-grounded corpus reproduced **161/161** on VM, but the **full e2e suite
failed 5 cases on VM-default** — proving the VM is NOT yet production-ready and,
more importantly, that **tree_walk-default was masking VM gaps** (the per-commit
gate only ran the e2e on tree_walk; VM was covered by unit+diff_test only). The
flip was reverted; the gaps are tracked as D-196.

## Decision

1. **VM is the intended production default** (F-012). tree_walk is retained as
   the differential oracle / reference implementation, always selectable via
   `-Dbackend=tree-walk`.
2. **The flip is GATED on D-196** — `build.zig` default stays `tree_walk` ONLY
   until every D-196 parity blocker is closed and the full gate is green under
   `-Dbackend=vm`. This is no longer silent drift: the interim default has an
   explicit, enumerated exit condition.
3. **VM gaps must stop being masked.** A VM-parity probe (`scripts/check_vm_parity.sh`,
   builds VM + runs e2e + corpus) tracks the failing-case count; it is
   informational until D-196 closes, then promoted to a hard per-commit gate so
   no new VM divergence is masked again.
4. On D-196 close: flip `build.zig` default to `vm`, mark F-012 reality-aligned,
   promote the VM-parity probe to a gate.

## The parity blockers (D-196, evidence = VM-default gate 2026-06-02)

| Gap                                                                   | e2e                                      | Status                                                   |
|-----------------------------------------------------------------------|------------------------------------------|----------------------------------------------------------|
| `catch :keyword` type dispatch                                        | phase14_catch_keyword                    | **CLOSED 2026-06-02** — op_match_type_keyword (D-014b)  |
| `(ns …)` `:refer-clojure :exclude` + libspec                         | phase14_ns_directive                     | VM-DEFER (D-098), compiler.zig:521                       |
| java-surface constructor (`(java.io.File. …)`)                       | phase14_java_static_dispatch             | **CLOSED 2026-06-02** — shared constructInstance        |
| dynamic error-context (`with-context`/`:request-id`, ex-info `:data`) | phase14_with_context, phase14_user_throw | **CLOSED 2026-06-02 — ADR-0071** (cleanup-handler kind) |

4 of the 5 e2e blockers are closed (catch-keyword via op_match_type_keyword;
the java-surface ctor via the shared `special_forms.constructInstance`;
error-context via [ADR-0071](0071_vm_cleanup_handler_kind.md)'s cleanup-handler
kind). **Only `(ns …)` `:refer-clojure` filter + libspec (op_ns_with_filter)
remains** before the build.zig default flip.

## Consequences

- The §349 intent is now law (F-012) with a tracked path, not a drifted memory.
- D-196 enumerates the work; closing each blocker is a VM backend cycle (verify
  on the VM build, not just tree_walk).
- The VM-parity probe prevents re-masking.
- No DA fork: the decision (VM is the default) is mandated by §349 + F-012 (user
  law) — there is no contested design choice, only the blocker list to clear.
