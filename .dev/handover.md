# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-366 license + D-368 agent-await race fix + zwasm
  alpha.2 tag-pin landed + pushed; Ubuntu serial gate 302/0 green).
- **First on resume MUST be (autonomous, overnight)**: the post-M quality loop
  (F-010), starting with **D-365 residual** — the bytecode-serializer **CHUNK
  round-trip gate** (side-table + field completeness; the 2 axes the Value-tag
  symmetry gate does not cover) — then **D-196 VM-parity** (run e2e + corpus under
  `-Dbackend=vm`, close the masked gaps toward the F-012 default-VM flip). Then
  continue the standing quality-loop floor drain per CLAUDE.md. Run autonomously.
- **Forbidden**: pushing to `main`. Do NOT pursue the **fly deploy (D-362)** in
  the autonomous loop — it is blocked-by fly's Petsem maintenance + needs
  user-driven fly actions; it is a separate user-triggered task (see D-362).

## Just landed — D-366 + D-368 + zwasm tag-pin + demo repos

- D-366 (`ca1578c9`) EPL-2.0 `clojure/**` attribution; D-368 (`7f12451c`,
  ADR-0093 am1) `await` delivers-after-`notifyWatches` (agent watch-race fix).
  Both Ubuntu-serial green (302/0).
- zwasm `v2.0.0-alpha.2` cut + pushed to clojurewasm/zwasm; build.zig.zon now
  tag-pins it (`a8ca2007`); jtakakura remote removed.
- **Demos**: clojurewasm/cw-playground + cw-serverless-demo created + pushed —
  fresh self-contained repos (carried from the now `_superseded-*-v2` dirs;
  Dockerfile + run_local clone+build cljw `-Dwasm`, zwasm via the tag pin;
  committed frontend-release + Wasm + PROVENANCE; bookshelf config.edn → env via
  direnv / fly secrets). Verified locally (run_local, API, playwright incl. live
  Google OAuth), self-reviewed clean. fly deploy deferred to D-362 (Petsem-blocked).

## Process discipline (SSOT)

- Gate cadence: per-commit `--smoke <step>` (don't block); batch full
  `bash test/run_all.sh` at boundaries. External zwasm / Defender load can
  CPU-starve the local gate; the Ubuntu remote gate (ubuntunote, load-immune) is
  the fallback — `timeout 1800 bash scripts/run_remote_ubuntu.sh` vs pushed HEAD.

## Cold-start reading order

handover → `.dev/debt.yaml` (**D-365** residual = NEXT; **D-196** VM-parity;
**D-362** = deferred fly deploy of the demos) →
`private/notes/D365-serialize-regex-symmetry.md` → CLAUDE.md § Autonomous
Workflow + F-010 quality loop.
