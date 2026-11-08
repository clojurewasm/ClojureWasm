#!/usr/bin/env bash
# test/e2e/phase16_wasm_component.sh — cljw↔wasm COMPONENT boundary (D-404 / ADR-0135).
# The wasm engine is zwasm's concern; this exercises the CLOJURE→wasm-component
# usage path: value marshalling, the cached-handle lifetime (REQ-7 instance
# caching), resource chains, every happy path, and that every error stays a
# catchable cljw exception (no exit-70 crash).
#
# OPT-IN, like phase16_wasm_ffi.sh / phase16_wasm_run.sh: it builds `-Dwasm` and
# is NOT in the default per-commit gate. During the local-accumulation phase the
# The zwasm dep resolves from the tag pin in build.zig.zon (fetched on any
# host), so this is not Mac-local.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

# Honor the gate's shared-binary contract (CLJW_SKIP_BUILD): skip our own build to
# avoid clobbering the shared binary mid-run. Standalone, build -Dwasm ReleaseSafe.
if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved? check the build.zig.zon pin)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

out="$("$BIN" test/e2e/fixtures/wasm_component_probe.clj 2>&1)" || fail "cljw exited non-zero:
$out"

for marker in \
  "PASS component-invoke-greet" \
  "PASS component-exports" \
  "PASS load-component-handle-reuse" \
  "PASS component-invoke-accepts-handle" \
  "PASS resource-chain" \
  "PASS one-shot-resource-outlives-call" \
  "PASS resource-handle-is-bound-to-its-component"; do
  grep -q "$marker" <<<"$out" || fail "missing: $marker
$out"
done

# Every error path must be CAUGHT (no NOT-CAUGHT, no exit-70 crash above).
grep -q "NOT-CAUGHT" <<<"$out" && fail "a component error escaped (catch …):
$out"
grep -q "^DONE$" <<<"$out" || fail "fixture did not run to completion:
$out"

echo
echo "Phase 16 / wasm component boundary: all green."
