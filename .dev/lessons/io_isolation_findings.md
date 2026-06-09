# Lessons — io subsystem + in-process isolation (ADR-0126 / D-355 / D-361)

Observational learnings from the clojure.java.io subsystem + the babashka-free
playground port. Re-derivable; not load-bearing ADRs (those are ADR-0125/0126).

## 1. Per-eval budget ≠ process-wide budget (the embedder footgun)

`CLJW_EVAL_MAX_STEPS` / `_DEADLINE_MS` / `_MAX_HEAP_MB` arm the **process-wide**
eval budget at startup (`eval_budget.installFromEnv`, runner.zig). For a
long-running embedder (an HTTP server that evaluates user code per request),
setting these as process env is a footgun: the **deadline trips a few seconds
into server uptime** and every back-edge afterwards (serving static files,
dispatching handlers) raises `resource_exhausted` → the server starts 500-ing
for no apparent reason.

The correct shape: the server runs **unmetered**; only the per-eval call is
bounded, via `cljw.eval/with-budget` (which saves+restores the ambient budget
over its dynamic extent). The playground learned this the hard way — it now
reads playground-specific `PG_EVAL_*` env into the with-budget opts and never
sets `CLJW_EVAL_*` process-wide. (commit: playground-v2 "fully drop babashka".)

**Takeaway for embedder docs:** `CLJW_EVAL_*` = whole-process kill-switch (good
for a one-shot `cljw -e`); `with-budget` = per-eval recoverable bound (good for a
server). Don't conflate them with one env name.

## 2. The live-heap ceiling is gc.alloc-only — infra bulk allocs bypass it (D-361)

`GcHeap.heap_ceiling` is checked inside `GcHeap.alloc` (GC-managed records). A
bulk allocation that goes through `gc.infra` directly bypasses it — notably the
**transient vector's element buffer** (`transient_vector.zig` grows via
`infra.realloc`). `(vec (range 1e8))` under a 16 MB cap grew that buffer to
~800 MB: a roomy host (macOS overcommit) tolerated it and tripped the cap later
at `persistent!`, but a memory-tight host (CI Linux) **OS-OOM-killed the process
first** — same code, opposite outcome, empty output + non-zero exit.

Fix: `GcHeap.checkInfraCap(bytes)` called at the bulk-infra site before the
realloc. **Lesson:** "the cap is at the alloc boundary" has a hole — `infra`
bulk paths need an explicit `checkInfraCap`. When adding a new per-N infra
buffer, wire the cap check.

## 3. Zig 0.16 cwd path: `std.process.currentPathAlloc(io, alloc)` (NOT getCwd)

0.16 removed `std.fs.cwd`-path / `realpath` / `posix.getcwd` (ziglang/zig#19353:
"realpath is unportable, a bug magnet"). The live accessor in the new io model
is **`std.process.currentPath(io, buf)` / `currentPathAlloc(io, alloc)`** (takes
`io` = `rt.io`). A grep for `getCwd` finds nothing and misleads you into
thinking the cwd path is unavailable (it cost D-357 a wrong "deferred" premise).
`std.os.linux.getcwd(buf, size)` is the raw syscall fallback. `std.Uri` (parse)
+ `std.http.Client` + `std.Io.net` are all present, so URL/URI/Socket host types
are buildable now (the deferral is phase-ordering, not a hard block).

## 4. A look-ahead, independent Linux gate surfaces cross-platform bugs cheaply

The ubuntunote gate runs on a **separate machine**, so launching it in the
background against a just-pushed HEAD costs ~nothing locally and runs in parallel
with continued local work. This is how D-361 (a macOS-passes / Linux-fails
heap-cap bug, latent for a whole session) was caught — the Mac per-commit gate
never would have. **Takeaway:** at a milestone, fire `run_remote_ubuntu.sh` in
the background as look-ahead; don't treat the Linux gate as a serial
phase-boundary-only step. (The empty-output + non-zero exit signature also
instantly ruled out the "error renderer re-breaches" hypothesis — a process
killed before printing anything is OS/timeout, not a render-path issue.)
