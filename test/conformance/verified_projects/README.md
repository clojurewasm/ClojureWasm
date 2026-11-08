# verified_projects — committed proofs that real Clojure libraries load on cljw

Each subdirectory is one real-world Clojure library that **loads and works on
cljw**, proven by a self-contained `deps.edn` (git-coordinate resolution +
a `:verify` alias) plus a `verify.clj` exercise run as `cljw -M:verify`. The
directory list is the at-a-glance answer to "which
libraries can cljw run today?" — a new `test/conformance/verified_projects/<lib>/` dir is visible
progress; growing the list is the F-013 / convergence-campaign Stage 1.3
coverage engine, run as committed artifacts instead of throwaway `-cp` probes.

Re-running them (`scripts/verify_projects.sh`) is also **regression detection**:
a later change that breaks a previously-working library fails its project here.

## Layout

```
test/conformance/verified_projects/
  <lib>/
    deps.edn     :paths ["."] + the lib via :git/url + :git/sha (a real GitHub
                 coord) + :aliases {:verify {:main-opts ["-m" "verify"]}}
    verify.clj   (ns verify (:require …)) + (defn -main [& _] …asserts…
                 (println "OK <lib>"))
```

The dir name is the human label (e.g. `medley`, `data.priority-map`). The
`deps.edn` is close to what a user would write to depend on the lib; cljw
resolves it source-only (`:git/url`/`:local/root`; `:mvn/version` is skipped per
ADR-0101 amendment 1 — `org.clojure/clojure` is cw itself, other coords resolve
at `require` time against cw's bundled namespaces). It adds `:paths ["."]` so the
local `verify.clj` (namespace `verify`) is on the classpath, and a `:verify`
alias whose `:main-opts` run `verify/-main` (the deps.edn `-M` run mode, D-309).
`verify.clj` must `assert` real outputs (not just `require`) and end with
`(println "OK <lib>")` so the sweep can report a one-line result.

The `-M:verify` shape is the canonical convention: it exercises the same
deps.edn run-mode path a real user invokes (`cljw -M:alias`), not a bespoke
script entry.

## Run

```sh
bash scripts/verify_projects.sh            # all projects (cljw -M:verify each)
bash scripts/verify_projects.sh medley     # one (by dir name)
```

**Network-dependent** (git clones into `$CLJW_HOME/gitlibs`, cached after first
run) — so it is **not** in the per-commit gate (`test/run_all.sh`). Run it on
demand and at **Phase boundaries**. The per-commit deps.edn *mechanism* test
(parse / resolve / `:mvn`-skip / git fetch) stays hermetic in
`test/e2e/phase14_deps_edn.sh` (a local bare repo, offline).

## Adding a library (the going-forward method, replacing corpus copies + `-cp`)

1. Find the lib in `docs/works/ladder.md` (the ranked candidate list) or pick a
   pure-Clojure lib. Get its GitHub URL + a commit sha (the `clojure-corpus`
   clone under `~/Documents/OSS/clojure-corpus/` is a convenient source:
   `git -C <clone> config --get remote.origin.url` + `git -C <clone> rev-parse HEAD`).
2. `mkdir test/conformance/verified_projects/<lib>` with `deps.edn` (`:paths ["."]` +
   `:git/url`+`:git/sha` + `:aliases {:verify {:main-opts ["-m" "verify"]}}`) and
   `verify.clj` (`(ns verify (:require …))` + `(defn -main [& _] …asserts… OK)`).
3. `bash scripts/verify_projects.sh <lib>` — runs `cljw -M:verify`; if it passes,
   commit the dir.
4. If it fails, the failure IS a coverage gap (F-013 discovery): fix the
   root-cause in cljw (definition-derived, not lib-specific), or — if the gap is
   in deps.edn resolution itself — improve the deps.edn system (within cljw's
   control; never a JVM/Maven JAR fetch). Then re-verify and commit.
5. Update `docs/works/ladder.md` so the ladder and `test/conformance/verified_projects/` stay in
   sync (the ladder ranks candidates; this dir holds the committed proofs).

## Relationship to the rest

- **memory `20260911004716-29dac88c` + `20260911004715-30c156bd`** — the PATTERNS behind this engine:
  the probe loop, the gap taxonomy (where each blocker class is fixed), and how to
  raise the coverage rate (read this before a re-expansion; this README is the
  *method*, the playbook is the *know-how*).
- **`docs/works/ladder.md`** — the ranked candidate ladder + the first-blocking
  gap per lib. A lib that reaches "loads" graduates into a `test/conformance/verified_projects/`
  entry (the committed, re-runnable proof).
- **memory `20260911004835-63674963`** (stage exits are mechanical predicates) — the campaign driver; this
  directory is its committed-artifact form.
- **ADR-0101** (+ amendment 1) — the deps.edn
  git-fetch + `:mvn`-skip mechanism these projects exercise.
