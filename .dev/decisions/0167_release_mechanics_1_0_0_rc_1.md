# ADR-0167 — Release mechanics for 1.0.0-rc.1 (the public-artifact readiness track)

- **Status**: Accepted (2026-07-01, user-directed: "1.0.0-rc.1 を目指す綿密な
  作業計画"; full-scope A+B, fully autonomous execution). Shape = DA-fork
  Alternative 2 (explicit finite readiness gate; B fully drained but
  non-blocking for the rc.1 *signal*).
- **Relates to**: ADR-0166 (public-ization polish sweep — the *internal-quality*
  drain: D-522…D-529), F-002 (finished-form), F-013 (single-binary public
  artifact). Sibling to ADR-0166: **0166 = internal polish (comments / docs /
  scaffolding / interop / parity); 0167 = the release *mechanics* an external
  clone needs (CI / community-health files / CHANGELOG / attribution /
  environment decoupling / version staging).** Reference template: the zwasm
  v2.0.0-rc.1 release series (S0…S7, `~/Documents/MyProducts/zwasm_from_scratch`).

## Context — why this ADR now

ADR-0166 framed the public-ization *quality* sweep but omits the concrete
**release machinery** a first external clone needs. An independent gap-analysis
against the zwasm v2 release series (S0…S7) found that CWFS is missing the entire
release-mechanics layer that zwasm shipped:

- **No CI at all** — `.github/` does not exist; an external contributor gets zero
  automatic verification on push/PR (zwasm called this "the headline
  public-readiness gap", S3).
- **Community-health files** — only `CONTRIBUTING.md` exists (and it is
  inconsistent with README's "Issues/PRs paused → Discussions" posture); missing
  `SECURITY.md`, `CODE_OF_CONDUCT.md`, `.github/ISSUE_TEMPLATE/config.yml`,
  `PULL_REQUEST_TEMPLATE.md`, `FUNDING.yml`.
- **No `CHANGELOG.md`**, no `THIRD_PARTY.md` (deps attribution beyond the EPL
  `NOTICE`), no `.gitattributes` (LF) / `.editorconfig`.
- **Personal-environment coupling** — `scripts/run_remote_ubuntu.sh` hard-codes
  the `ubuntunote` SSH host; `.claude/settings.json` carries personal
  `additionalDirectories`; two `src` comments leak author-local paths.

CWFS is otherwise in good public shape: README (logo, Discussions posture, no
internal-ID leaks), `--version` threaded from `build.zig.zon .version` as SSOT,
EPL-2.0 `LICENSE` + `NOTICE`, only 2 benign path leaks in `src`.

## Decision — the release-mechanics tracks (each a debt row, drained by Step 0.5)

**Track A — rc.1-blocking release mechanics** (finite, high-value; mirrors zwasm
S0-S3 + attribution + CHANGELOG):

- **D-536 (=S0) — debt-ledger code-truth reconciliation.** Reconcile the 84
  `active:` rows against code truth ahead of the public cutover; delete/narrow
  stale + false-positive rows (the zwasm S0 pattern). No source touched.
- **D-537 (=S1) — community-health files.** `SECURITY.md` (scope: a runtime
  executing untrusted Wasm bytecode; private reporting) / `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1) / `.github/ISSUE_TEMPLATE/config.yml`
  (`blank_issues_enabled: false` → Discussions) / `.github/PULL_REQUEST_TEMPLATE.md`
  (PRs-paused notice) / `.github/FUNDING.yml`. **+ reconcile `CONTRIBUTING.md`**
  with README's posture (Issues/PRs paused → Discussions; build instructions →
  `-Dwasm -Doptimize=ReleaseSafe`; the `--serial-e2e` full-gate caveat).
- **D-538 (=S2) — personal-environment decoupling.** SSH host →
  `${CLJW_UBUNTU_HOST:-ubuntunote}` (behavior-preserving default); the 2 `src`
  path-leak comments generalized; personal `additionalDirectories` moved to the
  gitignored `settings.local.json`.
- **D-539 (=S3) — CI wiring ★headline.** `.github/workflows/ci.yml`
  (push `main` + PR; macOS + Ubuntu matrix) driven by a single
  `scripts/ci_gate.sh` SSOT so **CI can never verify less than the per-host
  gate**; `.github/dependabot.yml` (weekly actions); a gitleaks config (reuse the
  existing `.gitleaksignore`); Zig 0.16.0 pin mirrored for CI.
  **CWFS-specific**: the full gate MUST run `--serial-e2e` (D-418 load-race) and
  probe a ReleaseSafe binary (ADR-0132).
- **D-540 (=CHANGELOG + attribution + formatting).** `CHANGELOG.md`
  (Keep-a-Changelog) added to `build.zig.zon .paths`; `THIRD_PARTY.md` naming
  **exact license + pinned version** per dependency (embedded zwasm = Apache-2.0
  @ `fc7ff0b3b` / `v2.0.0-alpha.3`; zlinter dev-dep = MIT; the EPL-1.0/2.0 clj
  lineage `NOTICE` records) — an EPL-2.0 project embedding an Apache-2.0 dep;
  `.gitattributes` (LF) + `.editorconfig`. Also ship `NOTICE` (currently absent
  from `.paths` despite the EPL `src/lang/clj/**` shipping inside `src`).
- **D-542 (=release-artifact workflow, PREPARED-not-fired).** A tag-triggered
  `.github/workflows/release.yml` that builds the static `cljw` binary for
  macOS + Linux (`-Dwasm -Doptimize=ReleaseSafe -Dcpu=baseline` for the deploy
  artifact, ADR-0132) and attaches it to the GitHub release. For a
  "single static binary" product (F-013) a pre-built `cljw` is most of what a
  non-Zig user needs. The workflow is authored and merged but **only fires on a
  tag the user pushes** — it does not tag (mirrors zwasm's `release.yml`).
- **D-543 (=dependency-pin coherence / reproducibility).** (a) Resolve the
  incoherent stability story of a `1.0.0-rc.1` embedding `zwasm v2.0.0-alpha.3`:
  either bump the pin to a coherent zwasm release once one exists (user-owned,
  co-dev CODEV), or document the version relationship explicitly in
  `THIRD_PARTY.md` + the zwasm-capabilities ledger as a known pre-1.0 coupling.
  (b) The `zlinter` dev-dep is fetched **eagerly** (a doc-reader's first
  `zig build` pulls an external repo — an offline/reproducibility footgun); make
  it lazy/dev-only if the build.zig restructure is tractable, else record it as a
  **named pre-1.0 wart with a tracking row** (not a bare "deferred").

**The rc.1 readiness gate is FINITE and explicit** = Track A (D-536…D-540) +
D-542 + D-543(a-doc/b-decision) + version staging (D-541). This finite set is
the SSOT for "can the user cut the `1.0.0-rc.1` tag?" — recorded as a checklist
in `handover.md` and kept code-true by the D-175 audit. A *release candidate* is
gated on a finite, honest readiness set, **not** on an open-ended discovery loop.

**Track B — the ADR-0166 internal-quality drain (D-522…D-529)** is, per the
user's full-scope decision (2026-07-01), **fully drained** (comment
de-pointering + condensation, doc audit vs code-truth, `private/` decoupling,
rules/skills review, java-interop static-member gap fill, clj-parity upstream
alignment, real-`deps.edn` library usage, marker-comment inventory) — but as a
**parallel quality track that does NOT gate the rc.1 readiness signal**. This is
F-compliant: F-002 governs per-task quality, and since 2026-06-25 no longer
governs inter-task *order*; nothing requires a release candidate to wait until
all debt is zero (that would contradict rc semantics, and D-529 real-lib usage
is an F-013 *discovery* mechanism that surfaces open-ended new gaps by design).
Track B is drained EASIEST-FIRST alongside Track A; the two converge, but the
tag can be cut when the finite Track-A gate is green.

**Version staging (D-541, user-owned boundary).** All rc.1 preparation lands on
`main` **while `build.zig.zon .version` stays `1.0.0-alpha.1`** until the user's
bump. To avoid a transient SSOT contradiction (zwasm hit exactly this — a
dedicated "fix CHANGELOG version line" commit): the CHANGELOG rc.1 entry sits
under an **`## [Unreleased]` heading**, and every `1.0.0-rc.1` string in
CHANGELOG / THIRD_PARTY / docs is **staged text that the user's single
`.version` bump + tag activates**. The final `1.0.0-rc.1` bump **and the
`git tag`/publish are the user's action** — the loop prepares everything but
NEVER tags or publishes (build.zig.zon is the SSOT; "the user owns the value via
the release tag"). This ADR does not authorize the loop to cut the tag.

## Consequences

- An external clone gets: automatic CI verification on push/PR, the standard
  community-health files, a CHANGELOG, complete third-party attribution, and no
  author-home coupling in shipped files.
- Track A is pure additive/mechanical (no runtime behaviour change); Track B's
  code-touching rows (interop fill / parity / lib bugs) take the normal diff-oracle
  + corpus gate.
- The rc.1 tag becomes cuttable the moment the **finite** readiness gate (Track A
  + D-541/542/543) is green; the bulk `D-522` comment de-pointering (~3000 lines,
  gradual) and the open-ended `D-529` real-lib discovery continue draining in
  parallel **past** the tag without blocking it — this is the intended rc shape,
  not a wart.
- Named pre-1.0 warts (tracked, not silently deferred): the eager `zlinter`
  dev-dep fetch (D-543b) and the zwasm-pin/version-line coherence (D-543a).

## Alternatives considered

The following is the Devil's-advocate subagent's output (fresh context, briefed
with the active F-NNN constraints), reflected verbatim per CLAUDE.md § ADR-level
designs. Its recommendation (Alternative 2) was adopted.

> ## Leading finding: no F-NNN block
> None of the three alternatives requires violating F-002 / F-013 / the user-owned-tag invariant. In particular, **decoupling the rc.1-readiness gate from the Track-B quality drain does NOT violate F-002** — F-002 governs per-task quality and explicitly stopped governing inter-task order (2026-06-25); it does not say "release only when all debt is zero" (that would contradict the very notion of a release *candidate*). So the finished-form-clean option below is F-compliant and is recommended despite a larger diff.
>
> ## Alternative 1 — smallest-diff (label + gap-fill in place)
> Keep the draft's two-track structure verbatim; add only (a) crisp **blocking / non-blocking** tags to each debt row, and (b) three missing Track-A rows: release-artifact workflow, zwasm-pin coherence, README build-command accuracy.
> - **Better than draft**: removes the blocking-set ambiguity and closes the biggest contributor-facing gaps at near-zero restructuring cost.
> - **Breaks / risks**: leaves the "Track B folded into the same rc.1 goal" wording intact, so the scope-creep / indefinite-delay pressure persists culturally even if individual rows are tagged non-blocking. Half-measure.
>
> ## Alternative 2 — finished-form-clean (explicit rc.1 readiness gate as an SSOT) — RECOMMENDED
> Introduce a first-class, code-true **`release readiness gate`** enumerating the *finite* blocking set, and reclassify Track B out of the blocking set:
> - Blocking = Track A (D-536…D-540) + version-staging prep (D-541) + **new D-542 release-artifact workflow** (tag-triggered static-`cljw` build, *prepared-not-fired*, per the user-owned-tag invariant — mirrors zwasm's `release.yml`) + **new D-543 dependency-pin coherence** (align embedded `zwasm` to a released/pinnable tag consistent with the "v2" attribution claim — shipping a `1.0.0-rc.1` that embeds `zwasm 2.0.0-alpha.3` is an incoherent stability story; and resolve the eager `zlinter` fetch to lazy/dev-only OR document it as a named pre-1.0 wart with a tracking issue rather than a bare "deferred").
> - Track B (D-522…D-529) becomes a **standing parallel quality drain** — fully drained per the user's full-scope directive, but explicitly **NOT gating the rc.1 readiness signal**.
> - **Better than draft**: crisp and honest; matches what zwasm *actually* shipped (release.yml + versions.lock + contract canary, none of which the draft's D-539 mentions); decouples the unbounded F-013 discovery (D-529) from the release gate, so rc.1 can be cut when the finite set is done.
> - **Breaks / risks**: larger diff — recommend anyway per F-002. The readiness-gate doc is one more thing to keep code-true (fold into the D-175 5-lens audit). Reclassifying B as non-blocking must be worded so it does not read as softening the user's "full-scope A+B" call (mitigation: B is still fully drained; only the *gate coupling* is removed).
>
> ## Alternative 3 — wildcard (rc as the discovery vehicle; invert the sequence)
> Treat rc.1's explicit purpose as *inviting external friction*. Front-load only the honesty/safety-critical minimum — LICENSE/THIRD_PARTY completeness, SECURITY.md, README build accuracy, CI-verifies-what-the-gate-verifies, zero author-home leaks, and a `release.yml` producing binary artifacts — as a tight blocking set. Defer community-health niceties (FUNDING/CoC), comment de-pointering, doc-audit depth, dependabot to rc.2/final.
> - **Better than draft**: fastest *honest* exposure; the F-013 discovery loop gets real external input instead of synthetic `deps.edn` probing.
> - **Breaks / risks**: "rc" connotes feature-complete/stable, so a deliberately-rough rc risks a reputational-label mismatch — an alpha/beta posture fits this intent better, mildly tensioning the user's stated "1.0.0-rc.1" target. A first public impression missing CoC/templates reads as unfinished, and under-delivers on the "綿密な作業計画" the user asked for.
>
> ## Direct critique of the draft
> 1. **The rc.1 blocking set is internally contradictory.** Track B says D-522…D-529 are "folded into the same rc.1 goal," but Consequences says the ~3000-line D-522 de-pointering "may extend past the rc.1 tag." So is B blocking or not? Undefined. Folding the *entire* D-522…D-529 drain into the rc.1 goal is the wrong call — D-529 (real-lib usage) is an F-013 discovery mechanism that surfaces open-ended new gaps, and the ~3000-line sweep is explicitly gradual. Gating a release candidate on an unbounded discovery + open-ended sweep is a direct indefinite-delay risk. Fix: finite blocking set (Track A + version prep), B as parallel non-blocking drain.
> 2. **Missing Track-A items:** binary-release artifacts (CI verifies but produces no artifact; zwasm shipped `release.yml`) → D-542; dependency-pin coherence + eager zlinter fetch → D-543; README build-command accuracy (`-Dwasm -Doptimize=ReleaseSafe`) as an explicit row; THIRD_PARTY must name license + exact version.
> 3. **Version-string coordination hazard (zwasm already hit it).** `.version` stays `1.0.0-alpha.1` until the user's bump, yet D-540 references `1.0.0-rc.1`. Specify the staging convention up front (CHANGELOG rc.1 under `Unreleased`; all rc.1 strings staged text the bump activates) so a version-consistency check does not flag the prepared state.
> 4. **Consider a public-API/consumer contract canary** (zwasm shipped one). CWFS ships both a binary and an embeddable library; a pinned-consumer smoke would catch accidental API breakage before the tag. Non-blocking, cheap insurance.
>
> ## Non-binding recommendation
> Adopt **Alternative 2.** Make the rc.1 readiness gate an explicit finite SSOT (Track A + D-541 + D-542 + D-543); reclassify Track B as fully-drained-but-non-blocking; add the version-string staging convention. This keeps the user's full-scope A+B intent (B is still drained) while making "when can the user cut the tag?" answerable and finite.

**Adopted**: Alternative 2, with the version-staging convention (critique §3)
folded into D-541 and the consumer-contract canary (critique §4) recorded as a
non-blocking follow-up under D-539. Critique §1's contradiction is resolved in
the Decision section (finite gate + non-blocking B). The README build-command
accuracy (critique §2) is folded into the D-537 CONTRIBUTING/README reconcile.
