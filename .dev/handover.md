# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.3.0` (2026-07-17 engine follow, no API change). Latest release:
  **v1.5.1** (2026-07-17; zwasm-pin patch release on top of v1.5.0 =
  the ADR-0174 host-class campaign + Thread lifecycle; tap carries
  cljw 1.5.1 + zwasm). CHANGELOG is the release-history SSOT.
- **First task on resume MUST be**: self-select from the live
  `.dev/debt.yaml` `active:` list, easiest-first. D-563 / D-561 /
  D-316 / D-383 / D-522 (dedicated sweeps) are DISCHARGED since
  v1.5.0. Next candidates: **D-058** (error-renderer bundled-file
  context mis-attribution — probe recipe in
  `private/notes/d316-d383-meta-and-bootstrap-regex.md`), **D-564**
  residuals (Thread interrupt family, instance-method fills, Alt C
  class_registry SSOT), D-513 remainder.
- **Unreleased on main**: envelope v9 (op_var_meta — def-meta rides
  the AOT wire), computed def-meta (D-316), deserializer GC-rooting
  fix, Character getName/codePointOf name table (D-561),
  default-data-readers, deftest file:line. Next release owns the
  CHANGELOG entry.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`;
  bare `zig build` for a probe (use ReleaseSafe). **The FULL gate MUST
  run `--serial-e2e`, ALONE** (D-548 (a) future/promise SIGABRT + (b)
  pmap wall-clock stay load-sensitive; recurrence protocol in the row).
  **Never run a concurrent build during a gate.** `.claude/**` edits +
  cross-repo publishes may hit the auto-mode block — surface to the
  user. **D-549 distribution cluster (Docker/ghcr/notarization) is
  user-LOCKED**; **D-560 is trigger-gated** — neither self-selects.
  External-publish payloads need `test -s` + read-back guards (memory
  `external-publish-payload-guard`).

## Current state (2026-07-17; details = CHANGELOG + git log)

- **v1.5.0 released** — the ADR-0174 host-class campaign (user-directed
  2026-07-16): ONE canonical descriptor per class (fqcn = JVM FQCN for
  Java-surface-backed classes; the typed_instance two-descriptor split
  merged; `cljw.` prefix leak dead), bare/qualified class symbols
  resolve as values, member-miss = precise position-split diagnostics,
  `Class` first-class, System closed out (getProperties/getenv-0/
  clearProperty/identityHashCode/gc + in/out/err stdio streams),
  **Thread lifecycle** (ctor/start/join/isAlive/names/daemon +
  join-at-exit; live daemon at exit = JVM-exact hard exit — the
  ubuntunote teardown-race fix), constants + enum statics + Pattern
  flags-compile + Duration/parse + File temp, envelope v8, and the
  **compat_members gate** (`scripts/check_compat_members.sh` +
  `__dump-host-classes`; compat_tiers member lists machine-true,
  `opaque_members:` = deliberate skips). Binary: mac 7,073,240 B /
  linux ~8.01MB (ADR-0172 revision notes the conscious growth;
  README claim "about 7.5 MB").
- Binary-size campaign (v1.4.0, ADR-0172/0173) + the v1.3.x arc
  (Character UCD, ADR-0171 rt-ns merge, CIDER completion parity,
  D-562 AD inventory): see CHANGELOG.
- Debug tooling: `scripts/nrepl_send.py` (nREPL client),
  `scripts/clj_diff_sweep.sh` + corpora (now incl. `character.txt`,
  `hash_compare.txt`, `records_method_values.txt`),
  `scripts/binary_size_report.sh` (size report + claims check).
- nREPL is single-connection (serial accept, D-117(a)): a second
  client waits while an editor is attached — probe via a fresh server,
  not the editor's port.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (D-520 / D-386 / D-005/006).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc.
- **D-548** — residual low-core exposures (a) future/promise SIGABRT
  (b) pmap wall-clock; recurrence protocol recorded in the row.
- CIDER upstream banner patch draft:
  `private/notes/cider-clojurewasm-banner-patch.md` (user-side PR).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf
fusion→JIT (gap III)**. zwasm JIT (ADR-0200) is the cljw default;
remaining = components-through-the-JIT (zwasm-side, D-500). Distal —
needs a user nod; the §9.2.T public-ization sweep (easiest-first debt
drain) is the active near-term mode.

## Stopped — user requested

User instruction (2026-07-17): "どこか切りの良いところが来たら（取組中の
完遂）、pushして停止でOK". The in-flight D-383 unit was completed +
pushed. Resume at the Resume contract's first-task rule (easiest-first
debt drain; next candidate D-058).

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 (public-ization
sweep mode) → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
