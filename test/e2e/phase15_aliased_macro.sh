#!/usr/bin/env bash
# test/e2e/phase15_aliased_macro.sh — a macro called through an `:as` alias
# (`m/some-macro`) must be macroexpanded by the analyzer, exactly as the
# fully-qualified form (`mlib.core/some-macro`) already is.
#
# Regression: the analyzer's macro-detection path (`resolveMaybe`) resolved a
# qualified head with a bare `env.findNs(ns)` that does NOT translate require
# aliases, so `m/pick` fell through to a plain function call and its raw
# argument was analyzed as an ordinary symbol → "Unable to resolve symbol".
# Found via verified_projects/qbits.ex (`ex/try+ … (catch-data …)`). The
# fix mirrors `analyzeSymbol`: alias-translate, then own-interns-only (D-261).
# Layer 2 (e2e CLI).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A lib ns with a macro whose body returns a quoted form of its raw argument.
# If the macro does NOT expand, the analyzer sees `(m/pick undefined-sym)` as a
# call and chokes on `undefined-sym` — the exact failure the bug produced.
proj="$WORK/proj"; mkdir -p "$proj/src/mlib"
printf '{:paths ["src"]}\n' > "$proj/deps.edn"
printf '(ns mlib.core)\n(defmacro pick [sym] (list (quote quote) sym))\n' > "$proj/src/mlib/core.clj"

# --- Case 1: aliased macro call expands (the regression target) ---
got="$(cd "$proj" && "$BIN" -e "(require '[mlib.core :as m]) (m/pick wildname)" 2>&1 || true)"
[[ "$(last_line "$got")" == 'wildname' ]] || fail "aliased macro: got '$(last_line "$got")'"
echo "PASS aliased_macro_expands -> wildname"

# --- Case 2: fully-qualified form behaves identically (control) ---
got2="$(cd "$proj" && "$BIN" -e "(require 'mlib.core) (mlib.core/pick wildname)" 2>&1 || true)"
[[ "$(last_line "$got2")" == 'wildname' ]] || fail "qualified macro: got '$(last_line "$got2")'"
echo "PASS qualified_macro_expands -> wildname"

echo "OK — phase15_aliased_macro (2 cases) green"
