# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ~`dcb36855` (see git log — CFP P1-P9 packaged; 7 F-011 fixes landed
  this overnight). Active plan = ADR-0089 (A->B->C); AI-doable CFP exhausted,
  in Phase C.
- **First commit on resume MUST be**: **drain the found Phase-C backlog** (this
  overnight's clj-diff sweep of 18 surfaces found these, all turnkey-routed in
  debt.yaml): **D-263** radix literals `2r1010` (most bounded — tokenizer
  readNumber + base-N parse, hex is the model) → **D-264** `distinct`/`dedupe`
  eager-hang (lazy rewrite; NOTE the fn* self-name gotcha in the row) → **D-261**
  qualified-symbol over-resolution → **D-265** biginteger (low). Then continue the
  gap-hunt (`scripts/clj_diff_sweep.sh`, self-select new surfaces; D-210 standing
  floor). **OR** open **Phase B (concurrency, D-242/244/245)** with fresh context
  via the Phase-B reading list (ADR-0089). Mid-session prefer the bounded items.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/DEFERRED_USER_ACTIONS.md` — (1) **Sessionize
  submit by 6/13** (`SUBMIT_READY.md` is copy-paste ready); (2) v0.1.0 tag /
  Release + make `cw-from-scratch` the default branch (`P3_DEFERRED…`, tag
  collides with old v1 lineage → version decision); (3) edge-demo CRUD deploy
  (committed locally, `git push` + `fly deploy` are yours).
- **Forbidden**: re-doing CFP P1-P9 (done/packaged — git log + below); the 3 USER
  actions above (account / credential / product decisions — the safety layer
  blocks them); pinning an in-progress zwasm v2 state / a zwasm tag or v1 (F-001:
  v2 ONLY from `zwasm-from-scratch`; wasm findings = zwasm-side feedback-note
  no-code, cljw-side real fix); turning auto-collect ON (user-owned #4a'); editing
  .claude/rules/* (permission-blocked → surface); trusting ~/Documents/OSS/zig.

## CFP campaign (D-256) — AI-doable parts DONE this overnight (git log = SSOT)

- **P1** wasm FFI (`wasm/load`+`wasm/call` behind `-Dwasm`, ADR-0099, →42;
  handle=D-259). **P9** `wasm_trap` Code + sandbox/trap demo (examples/wasm/trap.*).
- **P2** README/quickstart/LICENSE(EPL-2.0)/CONTRIBUTING + ARCHITECTURE refresh.
  **P4** binary size locked (bench/RELEASE_METRICS.md: ReleaseSafe ~2.2MB / ~5ms).
  **P5** docs/landscape.md. **P6** SUBMIT_READY.md (copy-paste, pivot-reconciled).
- **D-257** http request :body/:headers/:query-string. **P8** edge-demo guestbook
  CRUD (in `~/Documents/MyProducts/edge-demo`, committed LOCAL only — push+deploy
  user-gated). **D-260/ADR-0100** the `'` ops auto-promote (was inverted-strict).
  **index-of/last-index-of** accept a char needle. **D-261** recorded (cljw
  over-permissively resolves a fully-qualified non-interned `ns/name`).
- **P7** (browser Playground, cljw→wasm32) stays deferred (3 blockers).
  **P10/P11** (getting-started, slides) are post-acceptance + partly user-owned.

## Active plan — ADR-0089 post-M re-cut (2026-06-04)

```
Phase B  KNOWN-unimplemented CORE, concurrency-led (D-242): §7 redesign vs Zig
         0.16 FIRST, then STM-txn / agent / locking / real-threading / Thread +
         arrays (F-004) / *out*·in·err (D-238) / reflection. finished-form.
Phase C  Library-driven gap-hunt; workaround remediation folds in here.
```

## Open carry-overs (actionable)

- **D-259** wasm FFI provisional handle (Phase-16/F-004) · **D-258** dormant
  multi-thread torture flake (D-244 #4) · **D-261/263/264/265** Phase-C backlog.
- **3 rules** keep a stale `src/runtime/host/**` glob (ADR-0029); cleanup Edit is
  permission-blocked as self-mod (memory `claude-rules-edit-permission-block`).
- **D-243** (8 re-opened deferrals) · **D-244** #4a' hardening capstone (auto-
  collect dormant) · **D-245** locking Option C · **D-246** concurrency metadata.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source work only): `timeout 1800 bash test/run_all.sh --serial-e2e`
  (~5min; -P8 over-runs under load). Doc-only = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh` (ReleaseSafe shipped; never time Debug). Edit/Write
  TRANSCODES literal non-ASCII (keep source ASCII; splice non-ASCII via python).
  Default backend = VM (F-012).

## Cold-start reading order (tracked-only)

handover → **`private/clojure_conj_2026_cfp/SUBMIT_READY.md` +
`DEFERRED_USER_ACTIONS.md`** (CFP state) → `.dev/debt.yaml`
D-261/263/264/265 (the found Phase-C backlog) → **`.dev/decisions/0099_*`** (wasm
FFI) + **`0100_*`** (prime ops) → `.dev/project_facts.md` F-001/F-004/F-006/F-011
→ CLAUDE.md (§ Project spirit + The only stop) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-06): server-side limit hit — "きりのいいところで止めて
… 後処理" (stop at a clean breaking point; do the wrap-up). Stopped after
discharging D-262 (record map-protocol cluster); working tree clean, all pushed.
The next `/continue` deletes this section and runs the resume contract above.
Session net: CFP P1-P9 packaged + 7 F-011 fixes (D-257/D-260/index-of/Double-
special/char-name/record-seqable/record-map-protocol) + 18 surfaces parity-
validated + D-261/263/264/265 found & turnkey-routed.

Extended-challenge (per `.claude/rules/extended_challenge.md`):
1. **Alt hypothesis**: D-262's `map?`->true ripple was deferred twice on fatigue
   grounds, then landed safely once the gate validated it — lesson: a
   gate-validated ripple is not a defer reason (applies to D-263/D-264 too).
2. **Next experiment**: `./zig-out/bin/cljw -e '2r1010'` (→ name_error now), then
   fix D-263 (tokenizer readNumber `<digits>[rR]<base-N>` arm + base-N parse,
   model on the `0x` hex path); corpus `radix_literals`.
3. **Explicit blocker**: none — D-263 is a bounded reader fix, ready to run.
