# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `e64ebe14` (`cw-from-scratch`; see `git log` for drift). Tree clean,
  **0 unpushed**. Restart-safe (user did a manual PC reboot 2026-05-31).
- **First commit on resume MUST be**: the next clj-differential-sweep unit =
  **Java statics `Integer`/`Long`/`Double`/`Character`**. New
  `runtime/java/lang/Integer.zig` etc. (FQCNs are in `compat_tiers.yaml` but have
  no surface file yet). Step 0 survey first (AFTER confirming no gate is running —
  survey CPU contends with gate perf steps). clj-verified targets (master ledger
  § remaining Java interop gap): `Integer/parseInt` (+radix), `toBinaryString`,
  `toHexString`, `MAX_VALUE`/`MIN_VALUE`, `Long/parseLong`, `Double/parseDouble`,
  `Character/isDigit`/`isLetter`/`toUpperCase`. Pattern: `___HOST_EXTENSION`
  static descriptor (like `System.zig`/`Math.zig`), thin wrapper over neutral
  impl (F-009); delegate parse to the existing `parse-long`/`parse-double` in
  `lang/primitive/math.zig` where possible (F-011 DRY).
- **Operating mode** = clj differential sweep (F-011): probe a category through
  BOTH `clj` and `cljw`, diff, fix every divergence at the finished form;
  commonise rather than per-op patch. Deep/unresolvable → master ledger entry +
  `.dev/debt.md` D-NNN. Fully autonomous; do NOT stop.
- **Forbidden**: re-opening anything landed (git log = SSOT). JIT/superinstruction
  (perf deferred, D-163).

## Process discipline (load incident 2026-05-31 — now in memory + rules)

- **Never poll a background gate** with `sleep N; cmd` (harness-blocked). Launch
  `run_in_background`, yield, act on the completion notification, read once
  (memory `feedback-no-poll-background-tasks`).
- **`clj -M -e` MUST be `timeout 20`-wrapped** — infinite-seq (`(iterate inc 0)`)
  orphans pin ~160% CPU (`reference_clones.md` + `orphan_prevention.md` +
  `cleanup_orphans.sh` updated).
- **Never pass `\a`-style char literals through `cljw -e`** (shell eats the
  backslash); use `(char N)` (memory `char-literal-e2e-oracle`).
- **Under load, capture probe output to `/tmp/*.txt` and Read it**
  (channel-independent); don't trust a bare surprising read.
- **Defender exclusions added** (persist across reboot; `mdatp exclusion`):
  process `zig` + `{ClojureWasmFromScratch,zwasm,zwasm_from_scratch}/{.zig-cache,
  zig-out}` + `~/.cache/zig`. `managed_by: MDM` / `tamper_protection: block` —
  verify post-reboot via `mdatp exclusion list`, re-add any dropped.

## Current state

Mac gate green (171). AOT-bootstrap LIVE. Recent landings (git log = SSOT):
String `.charAt/.contains/.startsWith/.endsWith/.isEmpty/.concat/.repeat`
(14e7ab00); String `.replace` char/char + string/string, char-replace
commonised into `charset.replaceCharAlloc` shared by `clojure.string/replace`
(62cb796a); clj-oracle timeout hardening (334824d1). Invariants: **F-011**
(commonisation/clean/behavioural-equivalence over effort; clj oracle wired) +
F-010. ADRs 0059 (class/type), 0060 (catch).

## Master divergence ledger (compaction-survival)

[`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
holds every clj diff (fixed + unresolved + acceptable), the oracle recipe, the
swept categories, and the remaining Java-interop gap list. **Read it first on
resume.** Per-task notes: `private/notes/phaseA26-*.md`.

## Open debts (deep clj divergences deferred; full rows in `.dev/debt.md`)

- **D-164** empty-seq≡nil: cljw collapses `()` to nil (`(list? '())`/`(seq? '())`
  false, `(= () nil)` true, empty filter/map/rest/flatten print "nil" not "()").
  **The biggest remaining clj parity gap** (structural; own cycle).
- **D-163** perf: collection/lazy/higher-order ~100µs/element (large reduce/range
  timeout). Deferred to F-010 post-M perf phase (NOT premature JIT).
- Earlier: D-160 sequence/eduction, D-155/156 HAMT, D-150 VM ctor, D-133 JIT.
- **Acceptable divergences (recorded, not bugs)**: `(class 5)`→`Long` not
  `java.lang.Long` (no-JVM, ADR-0059); `(float 1/3)` f64 not f32; set print order
  (unordered); `(rest "abc")` substring not char-seq (transitively char-correct).

## Cold-start reading order

handover → master ledger (above) → CLAUDE.md (§ Project spirit + Autonomous
Workflow + The only stop) → `.dev/project_facts.md` (F-011 + F-010) →
`.dev/principle.md` (Bad Smell) → `.dev/reference_clones.md` (clj oracle).

## Stopped — user requested

User instruction (2026-05-31): "PC再起動をわたしがやります。今の作業をきりよく
し、クリーンセッションからcontinueで継続できる、配線・参照チェーンを確認して
ください。" Tree clean, all pushed. Resume per the Resume-contract First-commit
line — Java statics Integer/Long/Double/Character.
