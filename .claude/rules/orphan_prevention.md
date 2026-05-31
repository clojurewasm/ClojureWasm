---
paths:
  - "**"
---

# Orphan-prevention discipline

Auto-loaded everywhere. Codifies the 2026-05-28 incident in which
a `cljw repl` pipe launched via `Bash(run_in_background: true)`
was inherited by PID 1 when the parent Claude session was
interrupted, then a downstream `grep` on that hung pipe spun in
EAGAIN-poll at 100% CPU for ~1h50m, triggering a Mac fan event.
Source: ADR-0049 § Context; D-128 row in `.dev/debt.md`.

## The rule

**Every `Bash(run_in_background: true)` invocation that drives a
long-running child process MUST be wrapped in `timeout 600 …`** (or
a justified larger value), so that a parent-session kill leaves no
PID-1-inherited spinner.

Long-running means anything that could outlive a single bash
turn — REPL pipes, remote SSH shells, benchmark loops, file
watchers, daemons. The 600-second default is the cw v1 ceiling: a
test run, a remote gate, a bench sweep should all complete inside
that window. Pick a larger explicit value (e.g. `timeout 1800 …`
for the Linux gate when it is unusually slow) — never omit the
wrap.

## Gate launcher: `scripts/run_gate.sh` (single gate, auto-reap)

The full Mac gate is the most-repeated background long-runner, and
the one most prone to **stacking into orphans**: a premature
task-completion notification (the harness can report a gate
"completed" while it is still at its e2e step under host load —
memory `premature-gate-notification`) tempts a second gate launch
while the first is still alive. Each gate forks e2e sub-shells +
`cljw -e` large-input probes; when a gate is killed/timed-out its
`cljw` children **re-parent to PID 1 and keep running** (the
`timeout` SIGTERM does not reach a different process group — see the
Caveat below), so the pile drives load to 10–17 and garbles tool
output. (Incident 2026-05-31.)

`scripts/run_gate.sh` makes "one gate at a time, no orphans"
**structural**: on each launch it reaps any prior `test/run_all.sh`
tree + any `cljw` orphaned to PID 1 (precise — ppid==1 only, so a
live gate's children and interactive `cljw` are untouched), then
`exec`s `timeout ${GATE_TIMEOUT:-300} bash test/run_all.sh`.
`.dev/.gate_pass` is still written by `run_all.sh`, so the cadence
hook is unaffected.

- **Launch a gate**: `bash scripts/run_gate.sh` (preferred over raw
  `bash test/run_all.sh` — CLAUDE.md Step 5).
- **Reap on demand** ("notice → kill", no gate):
  `bash scripts/run_gate.sh reap`.

The SessionStart `~/.claude/hooks/cleanup_orphans.sh` (etime > 30 min)
remains the cross-session backstop; `run_gate.sh` is the intra-session
guard the 30-minute threshold is far too coarse for (a stale gate at
5 min is already an orphan).

## Failure modes the wrap defeats

1. **Parent-session-kill orphan**: Claude Code's bash subprocess
   exits on session interrupt; child processes started with
   `run_in_background: true` are re-parented to PID 1 (launchd /
   init). Without a `timeout`, they live forever.
2. **Hung-stdin poll spin**: a `grep` (or any blocking reader)
   downstream of an orphan'd REPL pipe sees `EAGAIN` repeatedly
   and burns a core. macOS thermal management responds with fan
   ramp-up; nothing inside the loop notices.
3. **SSH remote shell hold-open**: an interrupted `ssh user@host
   long-cmd` can leave the remote `long-cmd` running on the
   target host. `timeout` on the local side at least terminates
   the SSH transport (the remote may need its own discipline —
   see "Caveat" below).

## Caveat: `timeout` does NOT propagate

`timeout` kills the **immediate child** it spawned, not
descendants in a different process group. In particular:

- **Inside a VM / SSH session**: a `timeout 600 ssh host cmd` will
  kill the local `ssh` client at T+600s, but the remote `cmd`
  keeps running on the target host. For remote work, also script
  a remote-side guard (e.g. `ssh host 'timeout 600 cmd'`) or use
  `ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4` so a
  disconnect terminates the remote sooner.
- **REPL pipes that fork**: if the wrapped command forks a child
  that detaches (`setsid` / `nohup`), `timeout`'s SIGTERM at
  T+600s reaches the wrapper but not the detached grandchild.
  Prefer not to spawn detached children from a background pipe.
- **Process groups**: `timeout --foreground` and `timeout
  --kill-after=N` give finer control when the default SIGTERM is
  ignored. Reach for them if SIGTERM is not sufficient.

## REPL-pipe-specific hazard

The 2026-05-28 incident's specific shape: a long-lived `cljw
repl` started in background, with the parent shell intending to
`echo "(...)" | tee >(grep) | cljw repl`-style pipe data into it.
When the parent session is interrupted:

- The REPL process (alive, idle) gets PID 1 as new parent.
- The `grep` on the pipe sees the pipe's write side never close
  (the REPL is alive but not writing), and poll-spins on EAGAIN.
- Neither end is "stuck" from its own perspective; the orphan is
  the system that lost coherent ownership.

For REPL pipes specifically, prefer:

- **One-shot evaluation** via `cljw -e '(...)'` or `cljw - <<'EOF'
  … EOF` (per `cljw_invocation.md`) — no long-lived child to
  orphan.
- **`expect`-driven sessions** wrapped in `timeout 600 expect
  -f session.exp` — the expect process exits cleanly on EOF.
- **Background only with `timeout`**: `timeout 600 bash -c '...'`
  even for "fast" REPL sweeps; the wrap is cheap insurance.

If a long-lived REPL is genuinely needed (e.g. nREPL server),
launch it with `setsid` to detach from the controlling terminal,
and pair it with an explicit `pkill -f 'cljw nrepl'` cleanup at
session end — but this is exotic; the default is to avoid it.

## Discovery recipe (for framework-completion sweep)

Following `.claude/rules/framework_completion.md`, the discovery
recipe for this rule is:

```sh
rg --no-heading -n 'run_in_background.*true' .claude/ scripts/ \
  | grep -v -E 'SKILL\.md|orphan_prevention\.md'
```

Sweep at 2026-05-28 landing: 0 hits in tracked scripts (the only
match is `continue/SKILL.md`'s prose-level description of the
"Bash subagent" delegation pattern, which is conceptual, not a
literal long-running invocation). The rule is therefore
forward-looking — it constrains future cycles' background
invocations, not an existing population.

## Counter-examples

❌ `Bash(command: "ssh ubuntunote 'bash test/run_all.sh'",
run_in_background: true)` — no `timeout`. Orphan'd remote shell
on session kill.

❌ `Bash(command: "(while true; do echo ping; sleep 1; done) | grep
pong", run_in_background: true)` — infinite loop without
`timeout` is the canonical fan-event recipe.

✅ `Bash(command: "timeout 600 bash scripts/run_remote_ubuntu.sh",
run_in_background: true)` — wrapped; SIGTERM at T+600s ends both
the local script and the SSH transport.

✅ `Bash(command: "timeout 1800 bash test/run_all.sh",
run_in_background: true)` — explicit larger budget for the Mac
gate; still bounded.

## Stale-ness

This rule is stale if:

- A new hazard surface lands (e.g. WASM runtime daemon long-lived
  in tests) without a matching counter-example here.
- `timeout` semantics change (unlikely; POSIX-stable for years).
- The 600-second default proves wrong for the Mac gate or the
  remote gate (current p95 is well under 600s; bench at Phase
  boundary).

## Related

- `~/.claude/CLAUDE.md` § "全プロジェクト共通" — global advisory
  about orphan hazard + the SessionStart cleanup hook.
- `.dev/decisions/0049_retire_orbstack_per_commit_gate.md` § Context
  — 2026-05-28 incident narrative.
- `.dev/debt.md` D-128 — the row this rule discharges.
- `.claude/rules/cljw_invocation.md` — the safer `cljw` entry
  points (`-e` / heredoc / file) that avoid long-lived REPL pipes
  altogether.
