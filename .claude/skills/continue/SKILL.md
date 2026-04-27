---
name: continue
description: Resume fully autonomous work on cw-from-scratch and drive the per-task TDD loop until the user intervenes. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", "次", "go", or starts a fresh session expecting prior context. Reads handover, finds next task, runs tests, then immediately enters the TDD loop with no "go" gate, no Phase-boundary stop, and no per-task confirmation. Auto-runs the Phase-boundary review chain inline (under multi-agent fan-out) and continues into the next Phase without prompting.
---

# continue

Pick up where the previous session left off and **drive the iteration
loop fully autonomously**. The user invoked `/continue` precisely so
they would not have to babysit every checkpoint — only stop when
something *requires* the user (push approval, ambiguous bug, hard
block, ADR-level decision).

This skill is **opinionated about context discipline**: it delegates
heavy reads to subagents, compacts proactively, and resets at phase
boundaries. The ClojureWasm project is long-running; without these
disciplines, late-session quality degrades.

## When to stop, when to keep going

Default = keep going. **Keep going** when:

- The next step is mechanical (next TDD task in §9.<N>, doc commit,
  handover update, opening the next Phase).
- A test fails and the fix is local + obvious.
- A pre-approved tool prompts (the permissions allowlist + `defaultMode:
  acceptEdits` should keep these to a minimum).
- A Phase closes — run the review chain inline (multi-agent fan-out),
  report findings briefly, then immediately open §9.<N+1>. **Do not
  ask permission to start the next Phase.**
- The initial summary was just produced — **do not wait for "go"**;
  proceed directly into the TDD loop.

**Stop and ask the user** only when:

- A `git push` is needed (always — out of scope for autonomous mode).
- A test failure root cause is unclear or requires an architectural
  choice (i.e., not a one-line obvious fix).
- The audit-scaffolding skill produces a `block` finding.
- An ADR-level decision is needed (tier change, principle deviation,
  scope cut).

## Resume procedure (run on every session pickup)

1. Read `.dev/handover.md`. (The `SessionStart` hook already prints it.)
2. Read `.dev/ROADMAP.md`:
   - Find the IN-PROGRESS phase in §9. If none, take the first PENDING.
   - In that phase's expanded §9.<N> task list, find the first `[ ]`
     task. If §9.<N> is missing/empty, the phase has not been opened yet.
3. `git log --oneline -10` — identify any unpaired source commits since
   the last `docs/ja/NNNN-*.md` commit.
4. `bash test/run_all.sh` — confirm the build is green. **If the test
   output is large (>200 lines), run via subagent and ask only for
   pass/fail + the first failure.**
5. Summarise to the user in 5–10 lines:
   - Phase (number + name)
   - Last commit
   - Test status
   - Unpaired source SHAs (if any) — must be addressed first
   - Next task (number + name + exit criterion)
6. **Immediately proceed into the TDD loop.** Do not wait for "go" —
   `/continue` itself is the go signal.

## Per-task TDD loop (autonomous from invocation through chapter commit)

For each `[ ]` task in §9.<N>, run **Steps 0 → 8** in order. **Steps
0 and 5 default to subagent**; the rest run in main.

### Step 0 — Survey (subagent: Explore, default mode "medium")

Skip only if the task is *clearly* a continuation of a prior task
(refactor, rename, doc-only). Otherwise: dispatch one Explore subagent
to survey the textbooks. **Default brief**:

> Survey how `<concept>` is implemented in:
> - `~/Documents/MyProducts/ClojureWasm/src/...` (v1, 89K LOC)
> - `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/src/...`
>   (previous redesign Phase 1+2)
> - `~/Documents/OSS/clojure/src/...` and/or `~/Documents/OSS/babashka`
>   when semantically relevant
> Return 200–400 lines: file pointers, key data shapes, idioms used,
> what each codebase does *differently* and why. Do **not** copy code;
> describe the design space. Highlight 2–3 decisions where ClojureWasm
> v2 should likely diverge based on ROADMAP §2 principles.

The summary lands in `private/notes/<phase>-<task>-survey.md` (gitignored).
Read it, then proceed to Step 1.

See [`.claude/rules/textbook-survey.md`](../../rules/textbook-survey.md)
for when to skip Step 0 and how to avoid being pulled by upstream styles.

### Step 1 — Plan

One sentence in chat: the smallest red test that captures the next
behaviour. No permission needed.

### Step 2 — Red

Write the failing test (Edit / Write — auto-accepted). Run it; confirm
red.

### Step 3 — Green

Minimal code to pass. Resist over-design — the next refactor pass is
cheap.

### Step 4 — Refactor

While green. Apply only structural improvements that do not change
behaviour.

### Step 5 — Test gate (Mac + Ubuntu x86_64, run in parallel)

Run **both** in a single message with two parallel Bash tool calls:

- `bash test/run_all.sh` (Mac host — `aarch64-darwin`)
- `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'`
  (Linux `x86_64` — Bash timeout ≥ 600000 ms for cold builds)

Both must be green to proceed. The Linux run catches NaN-boxing /
HAMT / GC / packed-struct alignment regressions that would slip past
an Apple-Silicon-only run. If either output exceeds ~200 lines,
delegate to a Bash subagent and ask for "pass/fail + first failure
only"; otherwise inline.

Setup for the Linux side: `.dev/orbstack-setup.md`. If the VM is
absent (`error: machine not found`), surface to the user — do not
attempt to provision it autonomously (uses Mac admin context).

### Step 6 — Source commit

`git add` only the source files; `git commit -m "<type>(<scope>):
<one line>"`. The pre-commit gate runs. If the gate blocks for a
genuine reason, fix and re-stage.

### Step 7 — Per-task note (5 minutes, written from hot context)

Copy `.claude/skills/code-learning-doc/TEMPLATE_TASK_NOTE.md` to
`private/notes/<phase>-<task>.md`. Fill in:
- 一行サマリ
- 詰まったポイント (1–3 個)
- 教科書との対比 (Step 0 survey の要約を引き写す)
- 設計判断 (却下案)
- 章を書くときに必ず触れる点 (3–5 個)

This is **gitignored** — the gate does not touch it. The future
chapter writer will read this; you (now) won't.

### Step 8 — Context budget check

Estimate the current context fill. If above ~60% of the active model's
window:

1. Update `.dev/handover.md` to a clean post-task state (next task
   + retrievable identifiers).
2. Run `/compact` with a save brief listing: active phase, next task,
   architectural constraints in flight, opened private/ notes.
3. Re-read `handover.md` after compact.

If below 60%, continue immediately to the next task's Step 0.

### Repeat

Steps 0–8 for each `[ ]` task in §9.<N>. Multiple source commits in a
row are fine — the gate does not block.

### Chapter commit (per concept, not per task)

When 3–5 task-notes accumulate **and form a coherent concept**, or when
a phase is closing:

1. Pick a chapter slug (`docs/ja/NNNN-<slug>.md`).
2. Read the relevant `private/notes/<phase>-<task>.md` files. **These
   are the source material**, not `git log`.
3. Copy `.claude/skills/code-learning-doc/TEMPLATE_PHASE_DOC.md`.
4. Write the chapter: predict-then-verify exercises (L1/L2/L3),
   Feynman prompts, checklist, "次へ" link.
5. Commit alone: `git commit -m "docs(ja): NNNN — <title>
   (#<sha-list>)"`. The gate enforces `commits:` covers all unpaired
   source SHAs.
6. Mark progress in §9.<N>: flip `[ ]` → `[x]` for completed task(s),
   append the SHA in the Status column.
7. Update `handover.md` (1–2 lines + retrievable identifiers).

## Phase boundary review chain (auto-runs inline at multi-agent fan-out)

A Phase closes when the chapter commit's `commits:` list includes the
SHA that flipped the last `[ ]` to `[x]` in §9.<N>. Run this chain
**in parallel where possible** and **continue into §9.<N+1> without
asking**:

1. **Run audit-scaffolding** (slash command, prefer fork):
   `audit-scaffolding` produces `private/audit-YYYY-MM-DD.md`. Only
   **block-severity** findings stop the loop.
2. **In parallel** (multi-agent fan-out, single message with multiple
   Agent tool calls):
   - Subagent A (general-purpose): run built-in `simplify` on
     `git diff <phase-start>..HEAD -- src/` — apply behaviour-preserving
     suggestions; queue larger ones.
   - Subagent B (general-purpose): run built-in `security-review` on
     unpushed commits.
   - Subagent C (general-purpose): write any **outstanding chapter(s)**
     for the closed phase, pulling from `private/notes/` task-notes.
3. **Synthesise** results in main: 1 line per check + severity counts.
   No "shall I proceed?" question — proceed.
4. **Open §9.<N+1>**: flip the §9 phase tracker; expand §9.<N+1>
   inline (mirror §9.<N>'s structure); update handover.md to point at
   §9.<N+1>'s first task.
5. **Force a context reset**: write the new handover state, then
   `/compact` (or, if already low fill, `/clear` and re-read handover).
   Resume Step 0 of §9.<N+1>.1.

## Subagent delegation cheatsheet

| Trigger | Action |
|---------|--------|
| Survey ≥ 1 reference codebase / OSS | Step 0 — Explore subagent |
| Test output > 200 lines | Step 5 — Bash subagent (run_in_background if long) |
| Search across > 5 files | Explore subagent |
| Phase boundary audit / simplify / review | Multi-agent fan-out (parallel) |
| Outstanding chapters at phase close | general-purpose subagent |
| Single-file edit, < 200 lines context | Stay in main |

Default rule: **subagent fork on context isolation, not on importance**.

## What NOT to invoke during the loop

- `simplify` per source commit — overkill; queue for Phase boundary.
- `review` (PR-style) per commit — overkill; reserve for pre-push or
  pre-tag.
- `audit-scaffolding` per task — runs at Phase boundary only (or
  every ~10 chapters).

## Model selection (dual-model)

- **Per-task TDD loop (Steps 1–7)**: current session's model — Opus 4.7
  is fine.
- **Phase boundary chain (multi-agent fan-out)**: prefer **Opus 4.6**
  for the long-context audit / simplify / chapter-write subagents —
  Opus 4.7's MRCR v2 retrieval is known to degrade above ~100k tokens
  versus 4.6. Sonnet 4.6 is a viable cost-efficient alternative.

When unsure, default to subagent inheriting the parent model; flip to
Opus 4.6 only if a long-context task underperforms.
