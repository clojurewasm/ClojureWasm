# ADR-0101 — deps.edn `:git/url` resolution: `git` subprocess into a `~/.cljw/gitlibs` cache (Stage 1.2 slice 5)

- **Status**: Proposed → Accepted (2026-06-06)
- **Driven by**: Convergence Campaign Stage 1.2 slice 5 — `:git/url`+`:git/sha`
  deps are the last unresolved deps.edn coordinate; the real-world lib ladder
  (`docs/works/`) has `blocked: no deps.edn yet` rows that need a git source
  (e.g. `clojure.data.priority-map`).
- **Relates to**: F-002 (finished-form wins), `no_copy_from_v1` (re-derive v0's
  `resolveGitDep`, don't port), the source-only policy (ADR-less, established by
  the Stage 1.2 Maven reject — no JAR resolution), `zone_deps` (git_fetch.zig is
  app-layer, may spawn).

## Context

deps.edn `:paths`/`:local/root`/`:aliases` resolution landed (slices 1–4). The
remaining coordinate is `{:git/url "..." :git/sha "..."}`: fetch the repo at the
pinned sha and add its `:paths` (joined to `:deps/root` if present) to the
classpath.

**This is the first process-spawning code in cw v1.** `rg 'std.process.Child|std.process.run' src/` is empty — every prior feature is in-process. Spawning `git` is a new capability surface (subprocess, network, a user-data-controlled cache directory), which is why it is gated behind this ADR with a mandatory Devil's-advocate fork (CLAUDE.md § ADR-level designs are handled inline).

v0's `resolveGitDep` (cli.zig L736–940) is the prior art (read-only reference, NOT ported): cache at `~/.cljw/gitlibs/<sha-prefix>/<repo>`, `git clone` + checkout, `allow_fetch` gating, silent `return` on every error (HOME unset, clone failure). The cw-clean version must isolate the subprocess in its own module and surface real errors.

## Decision

1. **Module**: a new `src/app/deps/git_fetch.zig` (app-layer; `zone_deps` permits app→anything). It is the *only* file in cw v1 that spawns a subprocess; the isolation makes **`rg 'std.process.Child' src/`** return exactly one module, so the subprocess surface is auditable in one place. (The narrower `std.process.Child` invariant, not bare `std.process` — `std.process.exit`/`Init`/`currentPath` already appear runtime-wide; the DA's leading catch.)
2. **Spawn**: `std.process.Child.run(.{ .allocator, .argv = &.{"git", ...} })` (Zig 0.16). `git` is invoked by argv vector (no shell string), so a malicious `:git/url` cannot inject shell metacharacters — the URL is a single argv element passed to `git clone`.
3. **Cache (Shape B — content-addressed full sha)**: `$CLJW_HOME/gitlibs/<repo-name>/<full-sha>/`, where `CLJW_HOME` defaults to `~/.cljw` but is overridable; a hard `error_catalog` error (not a silent skip) when **both** `CLJW_HOME` and `HOME` are unset. Keying on the **full** sha (not a 12-char prefix) makes the cache content-addressed and lets multiple shas of one repo coexist without aliasing. This intentionally diverges from v0 / the JVM `~/.gitlibs/` layout (the "shared mental model" is weak — the caches are not interchangeable artifacts; see Consequences).
4. **Algorithm**: cache hit (the sha dir exists) → use it; miss → `git clone <url> <tmp>` then `git -C <tmp> checkout <sha>`, then **`git -C <tmp> rev-parse HEAD` and assert it equals `:git/sha`** (Shape B — catches a moved tag / tampered mirror), then atomically rename `<tmp>` → the cache dir (so a half-clone or SIGINT never poisons the cache). The cached dep's own `deps.edn` is then resolved transitively by reusing `resolve.zig` (the same `:paths`/`:local/root` recursion), with `:deps/root` appended as a subdir.
5. **Failure UX (cw-clean improvement over v0's silent return)**: HOME+CLJW_HOME unset, `git` not on PATH, clone failure, sha mismatch, or sha-not-found each raise a real `error_catalog` error rendered against the deps.edn source (the same startup-error path slice 3 added) — never a silent skip that leaves the user with a confusing downstream `lib_not_found`.
6. **Network boundary**: fetching is **on by default** when a `:git/url` dep is present (matching the `clojure` CLI). The trust boundary is the user's own deps.edn — the same boundary as `-cp` or running a `.clj` file. The post-checkout sha-verification (point 4) closes the one gap where "trusted like a classpath entry" does not hold (a network-resolved tag can move; a locally-authored path cannot). No further sandboxing of the fetched source.
7. **Testing (diverged from the DA — real subprocess, not an injected seam)**: the e2e drives a hermetic **local `file://` bare git repo** (created in the test via `git init --bare` + a commit), so it exercises the *actual* clone/checkout/rev-parse path offline with no GitHub dependency. A `command -v git` guard SKIPs (with a printed SKIP line, not a silent pass) where `git` is absent. No `GitFetcher` vtable: a single implementation does not warrant the indirection, and a fake fetcher would leave the new subprocess code untested (see § Main-loop disposition).

## Alternatives considered

Devil's-advocate subagent output (verbatim, fresh context, F-NNN envelope):

> **Leading finding (constraint check):** None of the three alternatives below requires violating `no_copy_from_v1`, source-only, or `zone_deps`. The finished-form-clean option is fully reachable inside the envelope, so there is no "the clean shape is blocked by an F-NNN/rule" entry to lead with. One factual correction the draft should absorb regardless of which shape wins: the claim that `git_fetch.zig` makes `rg 'std.process' src/` "return exactly one module" is **already false** — `std.process.exit`, `std.process.Init`, `std.process.currentPath`, and `std.process.executablePathAlloc` appear across `cli.zig`, `runner.zig`, `runtime.zig`, `System.zig`, `builder.zig`, etc. The auditable invariant the ADR actually wants is `std.process.Child` (subprocess spawning), which today returns *zero* hits. The Consequences/Decision-1 text should be narrowed to `std.process.Child` or the audit assertion is born a lie (the false-positive-trigger class the audit_scaffolding skill hunts).
>
> **Shape A — Smallest-diff: argv `git` subprocess, but defer fetch behind `:git/sha` verification + keep cache exactly as v0.** *Shape:* Essentially the draft as written (argv `std.process.Child.run`, `~/.cljw/gitlibs/<sha-prefix>/<repo>`), with one subtraction: do **not** add the atomic-rename tmp dance or transitive-resolve recursion in this slice — clone+checkout straight into the cache dir, resolve only the fetched repo's own `:paths` (no nested `:git/url`). *Better:* Smallest surface to land slice 5; the recursion and half-clone-poisoning are real but unexercised by the ladder's near-term rows (`data.priority-map` is leaf-like). It gets a git coordinate resolving today and lets the corpus prove it. *Breaks:* A clone interrupted by SIGINT leaves a partial cache dir that the next run treats as a hit (the exact footgun the draft's atomic-rename fixes) — so this is strictly *worse* on finished-form cleanliness, and re-opening the cache module later to retrofit atomicity is rework the draft already avoided. Dropping transitive git-recursion also means a dep-of-a-git-dep silently fails to load; that is a correctness gap, not a scope deferral. This shape only "wins" on diff size, which is not a project constraint — flagging it as the Cycle-budget-defer smell.
>
> **Shape B — Finished-form-clean: argv `git` subprocess + content-addressed cache keyed on the *resolved* sha, with the subprocess capability modeled as an injected `GitFetcher` vtable so the network boundary is testable without a real `git`.** *Shape:* Keep argv `git` (not libgit2, not pure-Zig — see Recommendation), keep clone+checkout, keep the atomic tmp→rename. Two upgrades over the draft: (1) **Cache key on the full resolved sha, not a 12-char prefix**, and lay it out `$CLJW_HOME/gitlibs/<repo-host>/<repo-path>/<full-sha>/` with `CLJW_HOME` defaulting to `~/.cljw` but overridable, and a hard error (not silent skip) when HOME is unset *and* `CLJW_HOME` is unset. Full-sha keying makes the cache content-addressed and lets multiple shas of the same repo coexist without collision; a 12-char prefix is a gratuitous truncation that can alias and has no upside now that disk is cheap. (2) **Model the spawn as a `GitFetcher` interface** (a struct of fn pointers on the deps-resolve context, default impl = the argv-`git` one in `git_fetch.zig`), so the e2e and unit tests inject a fake fetcher that populates the cache from a fixture dir — no `git` binary, no `file://` repo, no network, fully deterministic. The fetch-on-by-default + "trusted like -cp" trust boundary stays (it matches `clojure` CLI and the user authored the deps.edn), **but** the resolved sha is verified: after checkout, assert `git rev-parse HEAD == :git/sha` and raise `error_catalog` on mismatch, so a moved tag or a tampered mirror is caught rather than silently classpath'd. *Better:* This is the shape a finished-form audit wants — content-addressed cache (no prefix aliasing, clean multi-version coexistence), the subprocess boundary is an injectable seam (so testing doesn't depend on `git` being on the CI PATH or on `file://` URL parsing quirks), and sha-verification closes the one place "trusted like a classpath entry" genuinely *doesn't* hold: a classpath entry is authored locally, whereas a `:git/url` resolves over the network where a tag can move under you. The vtable seam is also the natural place a future sandbox/lockfile hook lands without re-surgery. *Breaks:* Bigger diff than the draft (the vtable indirection + cache-key migration + rev-parse step). It also means the cache layout intentionally *diverges* from JVM `~/.gitlibs/` and from v0 — losing the "shared mental model" the draft cites as a benefit. That benefit is weak (cw and JVM caches are not interchangeable artifacts; a user clearing one still clears the other by path), so the divergence is acceptable, but it must be named in Consequences so it isn't a silent break of the draft's stated goal.
>
> **Shape C — Wildcard: defer `git` subprocess entirely; ship `:paths`+`:local/root` for slice 5 and resolve `:git/url` by fetching a source *tarball* over the existing-or-new HTTP surface into the same content-addressed cache — no `git` binary on PATH, no subprocess at all.** *Shape:* No `std.process.Child`. For `{:git/url :git/sha}`, derive a codeload/archive URL (GitHub/GitLab expose `…/archive/<sha>.tar.gz`), fetch via `std.http.Client`, unpack into `$CLJW_HOME/gitlibs/<host>/<path>/<sha>/`, resolve `:paths`. *Better:* Eliminates the entire new capability surface the ADR is gated on — no subprocess, no shell, no `git`-on-PATH dependency (a real friction for minimal containers and for the eventual wasm/edge target where spawning `git` is meaningless, which is cw's actual differentiator per F-010/F-012). A pure-HTTP fetch is far closer to "runs anywhere cljw runs" than "requires a POSIX host with git installed". *Breaks:* **This is the decisive flaw.** cw today has `std.http.Server` (the cljw-original http surface) but **no `std.http.Client`** — so this shape *adds a new HTTP-client network capability* rather than reusing existing surface, trading one new capability (subprocess) for another (outbound TLS HTTP client + tar.gz inflate + per-forge URL-shape knowledge). It is **not** source-only-violating (a source tarball is git source, not a Maven JAR/artifact), so it stays inside the rule — but it bakes in forge-specific URL templates (`github.com` → codeload, `gitlab` → different path, arbitrary `:git/url` self-hosted → no archive endpoint at all), which `git clone` handles uniformly. `:git/url` to a bare/self-hosted repo with no HTTP archive endpoint simply cannot be served this way. So C is more portable for the 90% (GitHub) and strictly broken for the long tail that `git` handles for free. It also can't reuse `git`'s credential/auth handling for private deps. Worth recording as the forward-looking option for the wasm/edge horizon, but it under-serves the general `:git/url` contract today.
>
> **Recommendation.** Adopt **Shape B**, with one explicit carve-out: argv-`git`-subprocess is correct *now* (libgit2 = a C FFI dependency cw has avoided everywhere and a heavier supply-chain surface; a pure-Zig git protocol client is a multi-month yak-shave that buys nothing slice 5 needs; deferring git entirely loses the `:git/url` contract). B's three upgrades over the draft — **content-addressed full-sha cache layout under an overridable `CLJW_HOME`**, **a `GitFetcher` injectable seam so tests don't depend on a real `git`/`file://` repo**, and **post-checkout `rev-parse` sha-verification** — are the parts a finished-form audit would otherwise force as rework, so per F-002 they belong in this slice even though they enlarge the diff. Fold in Shape C's *insight* (not its mechanism) as a Consequences note: the subprocess path is a host-bound capability that the wasm/edge horizon (F-010/F-012) will eventually need an HTTP-client alternative for — record it as a debt row, don't build it now. Finally, correct the ADR's `std.process` audit claim to `std.process.Child` so the "one module" invariant is true rather than a false-positive trigger.

### Main-loop disposition (within the F-NNN envelope; the DA is advisory, not binding)

**Adopted from Shape B**: (1) full-sha content-addressed cache under an overridable `CLJW_HOME` (default `~/.cljw`), hard error when both HOME and CLJW_HOME are unset — replaces the draft's 12-char-prefix layout; (2) post-checkout `git rev-parse HEAD == :git/sha` verification, raising `error_catalog` on mismatch; (3) the `std.process` → `std.process.Child` audit-claim correction (the DA's leading factual catch). (4) Shape C's insight recorded as a debt row (HTTP-client tarball fetch for the host-less wasm/edge horizon), not built now.

**Diverged from Shape B — the `GitFetcher` vtable seam is NOT adopted.** Two finished-form reasons (not cycle-budget — the cache + rev-parse upgrades above *enlarge* the diff and are adopted): (a) a vtable for a **single** implementation, with the only second impl (Shape C HTTP) genuinely deferred to a debt row, is speculative indirection — the Reservation-as-bias smell; the seam's right introduction moment is when the second impl actually lands. (b) A fake fetcher would test *everything except the actual `git` clone/checkout/rev-parse* — the riskiest, newest code in the slice — so it reduces coverage of exactly what is new. A hermetic `file://` bare-repo e2e exercises the **real** subprocess path and is the finished-form test; the DA's "git on CI PATH" concern is handled by a `command -v git` skip-guard (a clear SKIP, not a silent pass) rather than by abstracting the subprocess away.

## Consequences

- cw v1 gains its first subprocess + network capability, isolated to one
  module. A future audit (the campaign Final Stage) can assert
  **`std.process.Child`** (not bare `std.process`) appears only in
  `git_fetch.zig`.
- Real-world git-coordinate libs become loadable; the ladder's
  `blocked: no deps.edn yet` git rows can be probed.
- A new operational surface (the `$CLJW_HOME/gitlibs` cache, default
  `~/.cljw/gitlibs`) that users may need to clear; documented in `docs/works/`.
  The layout intentionally diverges from JVM `~/.gitlibs/` (content-addressed
  full-sha dirs) — the caches are not interchangeable, so the divergence costs
  nothing and buys collision-free multi-version coexistence.
- The subprocess path is a **host-bound** capability (needs `git` + a POSIX
  host). The wasm/edge horizon (F-010 / F-012) — cw's actual differentiator —
  cannot spawn `git`, so it will eventually need an HTTP-client tarball-fetch
  alternative (the DA's Shape C insight). Recorded as a debt row, NOT built now
  (it would add a new outbound-HTTP-client capability + per-forge URL knowledge
  that `git` handles uniformly).
- Tests that actually clone are network-dependent — the e2e uses a **local
  bare git repo** as the `:git/url` (a `file://` URL) so it is hermetic and
  offline (no GitHub dependency in the gate), guarded by `command -v git`.

## Affected files

- `src/app/deps/git_fetch.zig` (new) — the subprocess + cache.
- `src/app/deps/resolve.zig` — wire the `:git/url` dep arm (currently skipped)
  to `git_fetch` + transitive resolve.
- `src/main.zig` — test aggregator entry.
- `test/e2e/phase14_deps_edn.sh` — a hermetic `file://` git-dep case.
- `.dev/debt.yaml` — D-273 note (git coordinate now resolvable).
