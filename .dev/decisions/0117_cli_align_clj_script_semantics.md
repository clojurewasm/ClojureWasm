# ADR-0117 — CLI alignment to clj 本家: script vs eval-print semantics, `--version`/`--help`

- **Status**: Proposed → Accepted
- **Date**: 2026-06-08
- **Opens**: **D-322** (stdin `-` no-echo migration + no-args → REPL — the
  follow-on units staged out of this ADR's first commit; see Decision D).
- **Cross-refs**: ADR-0048 (`repl`/`nrepl` subcommands), ADR-0059 / AD-003
  (no-JVM class — sibling no-JVM surface decision), AD-007 (error Kind, the
  separate user-driven error-format call deferred here), F-002 (finished-form
  wins; cycle/diff/LOC is not a project constraint), F-009, F-011 (behavioural
  equivalence with JVM Clojure). Reference: cljw v0 `build.zig` /
  `src/app/cli.zig` (the version auto-derivation pattern).

## Context

The user directed: align cljw's CLI to JVM Clojure (`clj`) behaviour,
referencing cljw v0 for display clarity + version auto-derivation, resolving
the CLI divergences in one pass. Empirically measured (clj 1.12.4 /
2026-06-08):

| invocation        | clj 本家                                                                              | cljw v1 (before)                    |
|-------------------|---------------------------------------------------------------------------------------|-------------------------------------|
| `-e <expr>`       | eval + print each result (echo)                                                       | echo (match)                        |
| `<file.clj>`      | run as script, **no echo**                                                            | **echoes every top-level value**    |
| `-` (stdin, dash) | run stdin as script, **no echo** (clj deprecates `-`, points at `-M -`, also no-echo) | echoes every top-level value        |
| no args           | REPL                                                                                  | prints a `ClojureWasm` smoke banner |
| `--version`       | `Clojure CLI version …`                                                              | `Unknown option` (exit 1)           |
| `--help`          | tool help                                                                             | usage, no version banner            |

cljw's top-level echo on a **file** run is the load-bearing divergence: it
pollutes demo/bench output with `nil`/`#'user/x` noise and breaks the bench
oracle (`$CLJW file | head -1` is meant to equal the program's printed
result, but echo prepends every intermediate value). Removing file echo both
matches clj and unblocks the benchmark suite (STREAM 2) with no harness change.

## Decision A — `<file.clj>` runs as a script (no result echo)

`runSource` already takes a `print_results: bool`. `cli.zig` now sets it
`false` for a bare-file source (`print_results` local, flipped in the
file-open branch) and `true` for `-e`. A file thus prints only what the
program prints (`println`/`prn`); clj-faithful. The `-M`/`-X` run modes were
already `print_results=false`.

## Decision B — `-` (stdin) also runs as a script (no echo) — **target**

The finished form is **uniform**: `<file>` and `-` are both "source from
somewhere, run it"; only `-e` (and the REPL) echo. clj agrees: `clj -` is a
no-echo script (and is itself deprecated in favour of `-M -`, which is *also*
no-echo — deprecation does not bless an echo reading).

An earlier draft kept stdin echoing and recorded it as an accepted divergence
(AD-024), justified by "cljw's `-` is a pipe-friendly batch eval-print mode"
+ "no-echo would break ~150 e2e heredoc fixtures". The Devil's-advocate fork
(below) correctly identified that as **smallest-diff bias wearing a divergence
costume**: two of its three legs are cost/convenience arguments, which F-002
forbids as grounds, and the third (deprecation) does not support echo. **AD-024
is withdrawn.** stdin `-` → no-echo is the recorded target.

## Decision C — `--version` + `--help` banner (auto-derived)

`build.zig` reads `build.zig.zon .version` into a `build_options.version`
string (cljw-v0 pattern); `cli.zig` gains a `--version` arm
(`ClojureWasm v<version>`, exit 0) and prepends the same banner to `--help`.
The version string is **never hand-written** — it tracks the release tag the
user owns (currently `build.zig.zon` = `0.0.0`, so `--version` reports
`ClojureWasm v0.0.0` until the user bumps the tag; the loop does not invent a
version).

## Decision D — staging (what lands when)

This ADR's **first commit** lands Decisions A + C (file no-echo, version,
help banner) — they are complete, clj-faithful, gate-green, and deliver the
bench unblock. Decision B (stdin no-echo) is a 56-file e2e heredoc migration
(each echo-asserting `cljw - <<EOF` case gains an explicit `(prn …)` on the
asserted form) — a natural separate commit, tracked as **D-322** so it cannot
rot, executed as the immediate next unit. **no-args → REPL** rides D-322 too
(it has a banner-test + non-TTY-hang surface that wants its own care). The
transient file≠stdin inconsistency between the two commits is acknowledged
and closed by the follow-on, not shipped as the final shape.

The error-format alignment (clj `Execution error (<Class>)` vs cljw
`<loc>: <kind> [phase]`) is **out of scope** here — it is AD-007-adjacent
(no-JVM Kind) and the user is driving it interactively.

## Alternatives considered (Devil's-advocate, fresh-context fork — stdin `-` echo)

**Verdict on the draft (AD-024 "stdin keeps echo"): it is smallest-diff bias
wearing a divergence costume.** The rationale chain is revealing — two of its
three legs ("breaks ~150 e2e files", "becomes a pipe-friendly mode") are
cost/convenience arguments, and under F-002 cost is explicitly *not* a valid
reason. The third leg ("clj's `-` is deprecated") actually cuts the other way:
clj deprecates `-` *in favor of `-M -`, which is still no-echo script mode* —
it does not bless echo. So the honest finished-form answer is below as Alt 2,
and AD-024 should not be the lead.

**Alt 1 — Smallest-diff: keep echo, AD-024 (the draft).**
Better: zero churn; the heredoc harness (`cljw - <<EOF … EOF`) keeps working as
an "assert echoed result" fixture; ships today.
Breaks: F-011 parity (stdin now triple-diverges from clj script semantics);
creates an AD whose `derives_from` is really "we didn't want to rewrite tests"
— a rationalization that pollutes the AD ledger's credibility. Inconsistent
with item 2 (file = no-echo), so `cat f | cljw -` ≠ `cljw f`, a surprising
split.

**Alt 2 — Finished-form-clean (recommended lead): `-` is no-echo script mode,
exactly like `<file>` and clj.**
Better: true clj parity; one mental model — "stdin and file are both scripts,
only `-e` and the REPL echo"; no AD needed; `cat f | cljw -` == `cljw f` holds.
This is what shipped-cljw `-` *should* do if tests were irrelevant.
Breaks: ~150 e2e heredoc fixtures that assert echoed values. Per F-002 this
rewrite cost is **not** grounds for rejection — migrate them to `-e`/`-M -`-style
echo harness or wrap expected output in explicit `(prn …)`. The migration is
mechanical and is the correct sink for the effort.

**Alt 3 — Wildcard: split the surface — `-` = no-echo (clj-faithful), add
explicit `-M -` or a new `--eval-print -`/`-p` flag for the echoing batch mode.**
Better: gives both the clj-parity default *and* a first-class, *named* pipe-eval-print
mode (so the heredoc harness migrates to one explicit flag, not 150 rewrites —
far cheaper than Alt 2 while staying parity-clean); the echo behaviour becomes a
documented feature, not a silent divergence.
Breaks: adds CLI surface clj doesn't have (mild F-011 footprint, but additive,
not a divergence on a shared form); the new flag needs its own tests/help text;
risks scope-creep into the deferred REPL/arg-parsing cycle.

**Recommendation:** lead with Alt 2 (finished-form-clean, clj-faithful); if a
named echo mode is independently wanted, Alt 3 captures it cheaply without
compromising `-` parity. Do not lead with Alt 1/AD-024 — naming the test-churn
avoidance "an accepted divergence" is exactly the dressed-up smallest-diff the
prompt warns against.

**Main-loop disposition**: adopt **Alt 2** (the DA's lead). Alt 3's named echo
flag is declined — a batch eval-print mode is thin niche surface that a clean
cljw (and clj) would not carry just to ease test migration; the `(prn …)`
wrapping (Alt 2's path) is the honest cost. Alt 1/AD-024 is rejected as
rationalization.

## Consequences

- **Bench oracle unblocked**: file runs print only the program's output, so
  `run_bench.sh`'s `head -1` equals the result (STREAM 2 proceeds with no
  harness change).
- **Demos/bench output** lose the top-level echo noise.
- **D-322** owes: stdin `-` no-echo (56-file e2e migration via `(prn …)`) +
  no-args → REPL. Until discharged, `cljw -` still echoes (the transient
  inconsistency Decision D names).
- **`--version`/`--help`** report `build.zig.zon`-derived version; the user's
  release tag is the SSOT for the value.

## Affected files

- `build.zig` (version option from `build.zig.zon`).
- `src/app/cli.zig` (`print_results` from source kind; `--version`; `--help`
  banner).
- `test/e2e/phase3_cli.sh` (file no-echo contract + `--version`/`--help` cases).
- `test/e2e/phase14_with_context.sh` (file value cases wrapped in `(prn …)`).
- `.dev/debt.yaml` (D-322).
