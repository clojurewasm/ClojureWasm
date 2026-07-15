# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin `v2.2.0` (AOT-full-fidelity; from v2.1.0).
- **1.2.1 RELEASED (2026-07-14 JST, tag v1.2.1, user-authorized patch).**
  **ADR-0170 am1**: `cider/analyze-last-stacktrace` — the `*cider-error*`
  buffer works (numbered causes, frames innermost-first with
  clj/repl/project/dup flags + file-url, phase-routed overlays). DA Alt 2
  adopted: `*e` is the SINGLE error channel — set for EVERY caught REPL
  error (JVM parity; catalog errors materialize via allocExceptionLoc +
  new ExInfo.phase byte, reader branch included); `throw` stamps the live
  call stack (both backends). FIXED en route: a 1.2.0 nREPL
  use-after-free (evalImpl fed scratch-owned code into persist-lifetime
  evals — now persist-duped). Pre-tag: smoke green / conformance 0 DRIFT /
  verify_projects 19/19 / CI green (the user-named tag criterion). The
  local full gate failed 3× ONLY on D-548(a)'s ledger-recorded roaming
  SIGABRT sites (20/20 standalone, 8×-stress 1/8 vs the pre-change 3/8
  baseline, CI passes the same step) — recorded in D-548, NOT an am1
  regression.
- **1.2.0 RELEASED (2026-07-14 JST)** — the ADR-0170 nREPL re-architecture
  (CIDER end-to-end: sessions/completions/lookup/eldoc/errors; shared
  eval engine gave the CLI REPL `*1..*e`) + D-369 discharged (deftype
  editable/transient dispatch; O-045 fusion double-realization fixed).
  Details: CHANGELOG + the ADR.
- **1.1.0 RELEASED (2026-07-12)**; Homebrew tap LIVE
  (`brew install clojurewasm/tap/cljw`); D-549 residual (Docker/ghcr +
  notarization) stays user-LOCKED.
- **D-418 + D-559 agent/GC races DISCHARGED (2026-07-13)** — ADR-0150 am1;
  accepted cost = **D-560** (trigger-gated — do NOT self-select).
- **java.lang.Character COMPLETE (2026-07-15, user-directed)** — full
  static surface (47 methods + 70 static fields) + char instance methods
  (charValue/compareTo) + `(hash \a)`=97 clj parity. Classification
  flipped ASCII→full-Unicode: gen_unicode_case.py now also generates
  General_Category/bidi/props/numeric/mirrored tables (UCD 16.0.0) into
  unicode_category.zig; charset.zig evaluates the JVM formulas. The one
  member out: `getName` (explicit unsupported, **D-561** — size-heavy
  name table vs gap II). Corpus `clj_corpus/character.txt` (154 golden)
  locks parity; e2e phase14_character_statics extended. nREPL describe
  now advertises `versions.clojurewasm` (babashka-precedent CIDER-banner
  key; CIDER upstream patch draft + init.el advice:
  `private/notes/cider-clojurewasm-banner-patch.md`).
- **ADR-0171 LANDED (2026-07-15)**: the `rt` kernel ns is GONE — Zig
  builtins + bootstrap macros intern into clojure.core (home ns matches
  mainline: `(resolve '+)` → `#'clojure.core/+`; ns-publics parity);
  `__`-internals live in the new `cljw.internal` ns (macro expansions
  call them qualified). Retired AD-011/038/049 as PARITY (pins flipped);
  new AD-053 pins cljw.internal's existence. serialize VERSION 6.
- **COMPLETION PARITY LANDED (2026-07-16)**: nREPL `completions` now
  carries the built-in's sources — special forms + literals, vars
  (dash-fuzzy `ma-i`→`map-indexed`), namespaces/aliases (dot-fuzzy),
  classes (closed rt.types universe via the shared
  `runtime/host_class_resolve.zig`; **AD-054** pins the
  no-classpath-leak divergence), `Class/` static members
  (camelCase-aware — the require-less java-interop ask), interned
  keywords — by-name sorted. Fixture-driven e2e
  `phase14_nrepl_completion` (23 probes, JVM-free; capture/audit =
  `scripts/completion_oracle.py`). Character gained isEmoji×6 (UCD
  emoji-data.txt via the generator) + isJavaLetter(OrDigit); statics
  126/128 (out: TYPE by design, codePointOf = D-561). Var-existence
  gaps mainline completion shows (defmacro-as-var /
  default-data-readers / definline / defstruct) → the D-562 inventory.
- **AD INVENTORY DONE (2026-07-16, D-562 DISCHARGED)**: all 50 AD rows
  classified with live clj/cljw probes (checklist:
  `private/notes/D562-ad-inventory-checklist.md`). RETIRED as parity:
  AD-006 (parseDouble = exact Java grammar) + AD-014 (locking
  immediates; nil errors like clj). NARROWED: **AD-009** — every leaf
  hasheq formula aligned with clj (`(hash x)` is now clj-PORTABLE for
  data: strings/keywords/symbols/doubles/bools/uuids/ratios/BigDecimals;
  corpus `hash_compare.txt` locks 30+ goldens) + **AD-043** (string-family
  compare returns clj's compareTo magnitude). `defmacro` Var + `definline`
  landed. Residuals → **D-563** (record ns-qualification, Var source
  meta, default-data-readers/defstruct, temporal compare magnitudes).
- **1.3.0 RELEASED (2026-07-16 JST, tag v1.3.0 = the user-named landing
  point)** — pre-tag: full gate green (one run hit only the
  D-548(a)-recorded SIGABRT, standalone 3/3, recurrence recorded) /
  conformance 0 DRIFT / verify_projects 19/19 / CI green on every arc
  commit; release workflow published all 4 assets. **Homebrew tap
  BUMPED to 1.3.0** (user-authorized 2026-07-16 morning; `brew info`
  verified `1.2.1 → stable 1.3.0`, formula sha256 matches the live
  tarball). NOTE: the first tap PUT emptied the formula (a vanished
  scratchpad file piped as empty base64 — gh api sent content="")
  and was restored within a minute; guard every external-publish
  payload with `test -s` + non-empty checks before the API call.
- **First task on resume**: self-select from the live `active:` list,
  easiest-first (D-523's architecture/wasm-demo residual + D-522 drain 3
  landed 2026-07-14; D-430 is DISCHARGED — the prior pointer here was
  stale). Next D-522 candidates by density: diff_test.zig 95 / vm.zig 89 /
  print.zig 88. Emacs 実機 *cider-error* 確認 is a nice-to-have probe
  (per-task note Extended challenge).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`; bare `zig build`
  for a probe (use ReleaseSafe). **The FULL gate MUST run `--serial-e2e`** — canonical
  mode; the residual D-548 (a) future/promise SIGABRT + (b) pmap wall-clock remain
  load-sensitive (the D-418 agent_conj arm is FIXED). **Never run a concurrent
  build during a gate** (host contention → false timeout). `.claude/**` edits may hit
  the auto-mode self-modification block — surface those to the user. **D-549
  distribution cluster (brew/Docker/signing) is user-LOCKED** — never self-select.
  **D-560 is trigger-gated** (measured pause-time harm or F-006 amendment) — not
  an ease-drain row.

## Last landed (git log = SSOT)

2026-07-13/14 session: v1.2.0 (ADR-0170 nREPL re-architecture + D-369) and
v1.2.1 (ADR-0170 am1 *cider-error* + *e parity + UAF fix) released; D-522
drain 3; D-523 residual audit. All CI-verified.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (cheap levers exhausted; D-520 / D-386 / D-005/006).
- **D-439 sqrt(MathContext)** — the one BigDecimal remnant; a focused numeric cycle
  (correct rounding ×8 modes + JDK preferred output scale; base = the native Managed.sqrt).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc (foundational).
- **D-548** — residual low-core exposures (a) future/promise SIGABRT (b) pmap wall-clock;
  the (c) agent_conj arm is DISCHARGED via D-418. D-560 — trigger-gated (see above).
- (D-430 instaparse was DISCHARGED 2026-07-06 — end-to-end, 4 grammar
  classes == clj.)

## Stopped — user requested

User instruction (2026-07-14): 「今の対処などできりの良いところだと思ったら、
cronは停止してCI通ったところで停止してください。つぎの発火が来てもなにもしない」
→ その後「(cider-errorバッファ改善を) 次の課題として取り組み…mainのCIがグリーンに
なったところでパッチtagをきってリリースして止めてください。あとは任せます。寝ます」。
v1.2.1 tagged + released on CI green per the directive; session crons = none;
loop stopped. Resume: self-select from the live `active:` list (see First task).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT (ADR-0200) is the cljw default; remaining = components-through-the-JIT
(zwasm-side, D-500). Distal — needs a user nod; the §9.2.T public-ization sweep
(easiest-first debt drain) is the active near-term mode.

## Reading order (resume)

handover → **`private/notes/2026-06-25-debt-drain-order.md`** (easiest-first snapshot)
→ `yq` the live `active:` list → **ADR-0166** (public-ization sweep mode) → ROADMAP
§9.2.T. Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`gate_parallel_e2e_timeout`.

