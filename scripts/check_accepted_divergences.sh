#!/usr/bin/env bash
# scripts/check_accepted_divergences.sh
#
# Auto-defense for the accepted-clj-divergence SSOT (.dev/accepted_divergences.yaml).
# An "accepted divergence" is a behaviour where cljw INTENTIONALLY differs from
# JVM Clojure (rule: memory 20260909234822-74759eeb (accepted_divergences)). This gate makes the
# ledger trustworthy so a divergence cannot (a) be added without a justification,
# (b) drift out of sync with the docs or its pinning test, or (c) outlive the
# divergence it records (ADR-0208).
#
# Checks:
#   1. SSOT is well-formed YAML with a non-empty `accepted:` list.
#   2. Every entry has a non-empty `derives_from` (no lazy "just accept it").
#   3. Every entry's `pin` test path(s) exist. Entries whose pin starts with
#      "none" are exempt (value-dependent / identity-hash cases).
#   4. COVERAGE.md's "Acceptable divergences" section points at this SSOT.
#   5. Every entry carries a `check` (ADR-0208), exactly one of:
#        check: {expr: <forms>, clj: <rendering>, cljw: <rendering>}
#        check: {prose: <why no single expression can show it>}
#      A rendering is pr-str of the last form's value, `throws <SimpleName>` of
#      the root cause for a raise, or `aborts` when the process dies first.
#   6. STALE: an executable check whose recorded `clj` equals its recorded
#      `cljw` documents no divergence.
#   7. cljw side: every `expr` is evaluated on the built cljw ($CLJW_BIN,
#      default zig-out/bin/cljw) and must render exactly `cljw`. A mismatch
#      means cljw converged or changed shape: either un-accept the row or
#      re-record it, consciously.
#   8. clj side: when `clojure` is on PATH, every `expr` is evaluated on the
#      pinned reference Clojure and must render exactly `clj`. A mismatch means
#      the row's JVM claim is false. When `clojure` is absent this half is
#      SKIPPED with a banner; AD_CHECK_REQUIRE_CLJ=1 turns the skip into a
#      failure. A `clojure` that is not the tools.deps CLI (no -Sdeps, e.g. a
#      distro 1.10 launcher) fails loudly rather than skipping. AD_CHECK_CLOJURE
#      overrides the CLI path; set it empty to force the skip.
#
# Expressions go to files and through scripts/ad_check_render.clj, the one
# driver both runtimes run; nothing is passed with -e.
#
# Informational by default (exit 0). Pass --gate to exit 1 on a violation.
set -euo pipefail
cd "$(dirname "$0")/.."

SSOT=.dev/accepted_divergences.yaml
COVERAGE=test/diff/clj_corpus/COVERAGE.md
RENDER=scripts/ad_check_render.clj
CLJW_BIN="${CLJW_BIN:-zig-out/bin/cljw}"
# The reference side is pinned so a recorded `clj` rendering means one thing.
# AD-052 is about the JVM's default zone and locale, so those are pinned too.
CLJ_VERSION=1.12.4
CLJ_JVM_OPTS=(-J-Duser.timezone=Asia/Tokyo -J-Duser.language=en -J-Duser.country=US)
gate=0
[ "${1:-}" = "--gate" ] && gate=1
bad=0

run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

if [ ! -f "$SSOT" ]; then
  echo "check_accepted_divergences: MISSING $SSOT"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi

# 1. Well-formed + non-empty.
n=$(yq -r '.accepted | length' "$SSOT" 2>/dev/null || echo "ERR")
if [ "$n" = "ERR" ] || [ -z "$n" ]; then
  echo "check_accepted_divergences: $SSOT is not well-formed YAML"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi
if [ "$n" -lt 1 ]; then
  echo "check_accepted_divergences: $SSOT has an empty accepted: list"
  bad=1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rows"

ids=$(yq -r '.accepted[].id' "$SSOT" 2>/dev/null || true)
exec_ids=()
n_prose=0
for id in $ids; do
  row() { ID="$id" yq -r ".accepted[] | select(.id == strenv(ID)) | $1" "$SSOT" 2>/dev/null || true; }
  # 2. derives_from present.
  df=$(row '.derives_from // ""')
  if [ -z "${df// /}" ]; then
    echo "check_accepted_divergences: $id has no derives_from (every accepted divergence needs a justifying invariant/ADR)"
    bad=1
  fi
  # 3. pin paths exist (skip "none ..." pins).
  pin=$(row '.pin // ""')
  case "$pin" in
    none*|None*|NONE*) : ;;  # value-dependent / identity — exempt by design
    *)
      # Verify each path-looking token (test/...{.txt,.sh,.zig,.clj}) exists.
      # `.clj` is in the list because pins are migrating to cljw-native
      # clojure.test suites (test/clj/suites/*.clj). Without it a repointed pin
      # extracts ZERO paths, the loop below never runs, and the divergence
      # silently degrades from "pinned and verified" to "pinned in prose" —
      # a vacated check that reports success.
      for p in $(printf '%s\n' "$pin" | grep -oE '[A-Za-z0-9_./-]+\.(txt|sh|zig|clj)' || true); do
        if [ ! -e "$p" ]; then
          echo "check_accepted_divergences: $id pin path does not exist: $p"
          bad=1
        fi
      done
      ;;
  esac
  # 5. check present and well-shaped.
  shape=$(row '.check | (select(type == "!!map") | keys | sort | join(",")) // "none"')
  case "$shape" in
    prose)
      if [ -z "$(row '.check.prose // ""' | tr -d '[:space:]')" ]; then
        echo "check_accepted_divergences: $id check.prose is empty (say why no expression can show the divergence)"
        bad=1
      fi
      n_prose=$((n_prose + 1))
      ;;
    clj,cljw,expr)
      expr=$(row '.check.expr // ""'); clj=$(row '.check.clj // ""'); cljw=$(row '.check.cljw // ""')
      if [ -z "${expr//[[:space:]]/}" ] || [ -z "$clj" ] || [ -z "$cljw" ]; then
        echo "check_accepted_divergences: $id check has an empty expr, clj or cljw"
        bad=1; continue
      fi
      # 6. STALE: the two recorded sides agree, so the row records no divergence.
      if [ "$clj" = "$cljw" ]; then
        echo "check_accepted_divergences: STALE $id records the same rendering on both sides ($cljw): the divergence is gone or was never there"
        bad=1
      fi
      lc=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
      printf '(ns ad-check.%s)\n%s\n' "$lc" "$expr" > "$tmp/rows/$id.expr"
      printf '%s' "$clj" > "$tmp/rows/$id.want-clj"
      printf '%s' "$cljw" > "$tmp/rows/$id.want-cljw"
      exec_ids+=("$id")
      ;;
    none)
      echo "check_accepted_divergences: $id has no check (ADR-0208: add check {expr, clj, cljw} or check {prose})"
      bad=1
      ;;
    *)
      echo "check_accepted_divergences: $id check has keys [$shape]; expected exactly [expr, clj, cljw] or [prose]"
      bad=1
      ;;
  esac
done

# Compare one side's renderings ($1 = clj|cljw, $2 = file of "path<TAB>rendering").
compare_side() {
  local side="$1" got_file="$2" id got want
  for id in "${exec_ids[@]}"; do
    got=$(awk -F'\t' -v p="$tmp/rows/$id.expr" '$1 == p { sub(/^[^\t]*\t/, ""); print; exit }' "$got_file")
    [ -n "$got" ] || got="aborts"
    want=$(cat "$tmp/rows/$id.want-$side")
    if [ "$got" != "$want" ]; then
      if [ "$side" = cljw ]; then
        echo "check_accepted_divergences: $id cljw side changed: recorded [$want], cljw now renders [$got]"
      else
        echo "check_accepted_divergences: $id clj side is false: recorded [$want], clojure $CLJ_VERSION renders [$got]"
      fi
      bad=1
    fi
  done
}

# 7. cljw side, one process per row: a row that aborts must not take the rest
# down with it.
if [ "${#exec_ids[@]}" -gt 0 ]; then
  if [ ! -x "$CLJW_BIN" ]; then
    echo "check_accepted_divergences: no cljw binary at $CLJW_BIN (build first, or set CLJW_BIN); the cljw side is unverified"
    bad=1
  else
    : > "$tmp/cljw.tsv"
    for id in "${exec_ids[@]}"; do
      TZ=Asia/Tokyo LANG=en_US.UTF-8 run_bounded 30 "$CLJW_BIN" "$RENDER" "$tmp/rows/$id.expr" 2>/dev/null \
        | awk -F'\t' '$1 == "AD-CHECK" { sub(/^AD-CHECK\t/, ""); print }' >> "$tmp/cljw.tsv" || true
    done
    compare_side cljw "$tmp/cljw.tsv"
  fi
fi

# 8. clj side, one JVM for every row (start-up dominates; each row has its own ns).
clj_status="verified"
if [ "${#exec_ids[@]}" -gt 0 ]; then
  # AD_CHECK_CLOJURE names the Clojure CLI; set it empty to force the skip path.
  clojure_cli="${AD_CHECK_CLOJURE-$(command -v clojure 2>/dev/null || true)}"
  if [ -n "$clojure_cli" ]; then
    files=()
    for id in "${exec_ids[@]}"; do files+=("$tmp/rows/$id.expr"); done
    run_bounded 600 "$clojure_cli" -Sdeps "{:deps {org.clojure/clojure {:mvn/version \"$CLJ_VERSION\"}}}" \
      "${CLJ_JVM_OPTS[@]}" -M "$RENDER" "${files[@]}" 2>"$tmp/clj.err" \
      | awk -F'\t' '$1 == "AD-CHECK" { sub(/^AD-CHECK\t/, ""); print }' > "$tmp/clj.tsv" || true
    if [ ! -s "$tmp/clj.tsv" ]; then
      echo "check_accepted_divergences: clojure produced no renderings; stderr follows"
      sed 's/^/    /' "$tmp/clj.err" | tail -n 20
      bad=1
    else
      compare_side clj "$tmp/clj.tsv"
    fi
  else
    clj_status="SKIPPED"
    echo "check_accepted_divergences: +------------------------------------------------------------+"
    echo "check_accepted_divergences: | SKIPPED: clj side NOT verified (no \`clojure\` on PATH).      |"
    echo "check_accepted_divergences: | ${#exec_ids[@]} recorded JVM renderings are taken on trust this run.  |"
    echo "check_accepted_divergences: | Run on a host with clojure, or set AD_CHECK_REQUIRE_CLJ=1. |"
    echo "check_accepted_divergences: +------------------------------------------------------------+"
    if [ "${AD_CHECK_REQUIRE_CLJ:-}" = 1 ]; then
      echo "check_accepted_divergences: AD_CHECK_REQUIRE_CLJ=1 and the clj side cannot run"
      bad=1
    fi
  fi
fi

# 4. COVERAGE.md points at the SSOT (no drifting duplicate prose list).
if [ -f "$COVERAGE" ]; then
  if ! grep -q 'accepted_divergences.yaml' "$COVERAGE"; then
    echo "check_accepted_divergences: $COVERAGE 'Acceptable divergences' must point at $SSOT (it is the SSOT)"
    bad=1
  fi
fi

if [ "$bad" = 1 ]; then
  echo "check_accepted_divergences: VIOLATIONS found (see above)"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi
echo "check_accepted_divergences: ok, $n accepted divergence(s): ${#exec_ids[@]} executable (cljw side verified, clj side $clj_status), $n_prose prose"
