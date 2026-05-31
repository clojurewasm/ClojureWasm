---
paths:
  - "**"
---

# Orphan-prevention discipline

A background long-runner that outlives a bash turn gets re-parented to
PID 1 on session interrupt and can spin a core (Mac fan event). Two
incident narratives (2026-05-28 REPL-pipe poll-spin, 2026-05-31
clj-oracle infinite-seq) live in
[`ADR-0049`](../../.dev/decisions/0049_orbstack_linux_gate_retired.md)
§ Context.

## The rules

1. **Every `Bash(run_in_background: true)` that drives a long-running
   child** — REPL pipe, SSH shell, bench loop, gate, daemon —
   **MUST be wrapped in `timeout 600 …`** (larger only when justified,
   e.g. `timeout 1800` for a slow Linux gate). Never omit the wrap.
2. **Every `clj -M -e '…'` oracle probe MUST be `timeout 20`-wrapped
   AND bound sequence-producers with `(take N …)`.** `clojure.main -e`
   prints its result, so an unbounded seq (`(range)`, `(iterate inc 0)`,
   `(repeat 1)`, `(cycle …)`, `(line-seq …)`) realises forever and
   pins ~160 % CPU.

`timeout` kills only its immediate child, NOT descendants in another
process group: across an SSH/VM boundary the remote command keeps
running (use `ssh host 'timeout 600 cmd'` or
`-o ServerAliveInterval=30`); a `setsid`/`nohup` grandchild survives
too. Prefer one-shot `cljw -e '…'` / heredoc (per
[`cljw_invocation.md`](cljw_invocation.md)) over long-lived REPL pipes.

## Gate launcher

`bash scripts/run_gate.sh` (preferred over raw `test/run_all.sh`) reaps
any prior `run_all.sh` tree + PID-1-orphaned `cljw` before launching a
single gate; `bash scripts/run_gate.sh reap` reaps without launching.
The SessionStart `~/.claude/hooks/cleanup_orphans.sh` (etime > 30 min)
is the cross-session backstop and also reaps stray `clojure.main -e`
oracle JVMs.

## Counter-examples

- ❌ `ssh ubuntunote 'bash test/run_all.sh'` in background, no
  `timeout` — orphaned remote shell on session kill.
  ✅ `timeout 600 bash scripts/run_remote_ubuntu.sh`.
- ❌ `clj -M -e '(range)'` — unbounded print, no timeout.
  ✅ `timeout 20 clj -M -e '(take 5 (range))'`.
- Reap a stray oracle JVM: `pkill -f 'clojure.main.*-e'` (scoped —
  leaves IntelliJ / Gradle / interactive REPLs untouched).

## Related

- [`ADR-0049`](../../.dev/decisions/0049_orbstack_linux_gate_retired.md)
  § Context — full incident narratives.
- `~/.claude/CLAUDE.md` § 全プロジェクト共通 — global orphan advisory +
  the SessionStart cleanup hook.
- [`cljw_invocation.md`](cljw_invocation.md) — safe `cljw` entry points
  that avoid long-lived REPL pipes.
