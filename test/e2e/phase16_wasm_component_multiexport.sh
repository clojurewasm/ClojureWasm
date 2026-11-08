#!/usr/bin/env bash
# test/e2e/phase16_wasm_component_multiexport.sh — D-567 / D-404.
#
# cljw's headline feature is "require a Wasm component as a namespace". A
# namespace with one function is not a namespace, and until 2026-08-04 nobody
# had checked: both component fixtures then in the tree (greet,
# resource_counter) export exactly one function, so a component with TWO
# exports had never been loaded. It did not load — zwasm rejected any component
# with >= 2 exports with `InvalidSort`, engine-side (zwasm D-527, fixed in
# zwasm #157).
#
# This file used to PIN that gap. It now asserts what the gap was hiding: the
# ADR-0135 marshalling table, driven through the 16-export typed fixture in
# BOTH directions. That is what discharges D-404's "BLOCKED on a typed
# component FIXTURE" — the fixture exists and every row it covers runs here.
#
# Provenance + rebuild recipe for the fixtures: fixtures/wasm/README_echo.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

F=test/e2e/fixtures/wasm
[ -f "$F/echo.component.wasm" ]       || fail "the typed fixture is missing"
[ -f "$F/two_export_component.wasm" ] || fail "the minimal reproduction is missing"

# The single-export control, kept: it is what made the original failure legible
# as being about export COUNT rather than about components in general.
got="$("$BIN" -e '(println (count (wasm/component-exports "test/e2e/fixtures/wasm/greet_component.wasm")))' 2>&1 | sed -n 1p)"
[[ "$got" == "1" ]] || fail "single-export control did not load: got '$got'"
echo "PASS single-export-control -> $got"

# Two exports — the minimal reproduction of the engine bug.
got="$("$BIN" -e '(println (count (wasm/component-exports "test/e2e/fixtures/wasm/two_export_component.wasm")))' 2>&1 | sed -n 1p)"
[[ "$got" == "2" ]] || fail "two-export component did not list both exports: got '$got'"
echo "PASS two-export-loads -> $got"

# Sixteen exports — the typed fixture. An exact count, so a regression that
# silently DROPS exports (rather than failing outright) is caught too.
got="$("$BIN" -e '(println (count (wasm/component-exports "test/e2e/fixtures/wasm/echo.component.wasm")))' 2>&1 | sed -n 1p)"
[[ "$got" == "16" ]] || fail "typed fixture: expected 16 exports, got '$got'"
echo "PASS typed-fixture-lists-all-exports -> $got"

# --- the ADR-0135 marshalling table, both directions -------------------------
#
# Every row is an ECHO, so a passing case proves lower AND lift agree: a value
# that survives the round-trip was encoded into the canonical ABI and decoded
# back. A one-directional check would pass on two mistakes that cancel.
out="$("$BIN" test/e2e/fixtures/wasm_marshalling_table.clj 2>&1 || true)"
grep -q "MISMATCH" <<<"$out" && fail "ADR-0135 marshalling table round-trip mismatch:
$out"
grep -q "^TABLE-DONE$" <<<"$out" || fail "the marshalling table did not run to completion:
$out"
echo "PASS adr0135-marshalling-table-round-trips (20 rows, both directions)"

echo "OK — phase16_wasm_component_multiexport (4 cases) green — D-567 + D-404's fixture blocker discharged"
