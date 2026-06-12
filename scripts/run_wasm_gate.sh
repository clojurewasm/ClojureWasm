#!/usr/bin/env bash
# scripts/run_wasm_gate.sh — wasm-only quick runner (D-387 / ADR-0099 / ADR-0124).
#
# Since F-001 was amended 2026-06-12 (zwasm v2 complete), the DEFAULT
# `test/run_all.sh` gate ALSO covers the wasm e2e (builds `-Dwasm` throughout,
# ADR-0133) — so this is no longer the *only* wasm coverage. Keep it as a fast
# wasm-only path: build `-Dwasm` + run just the two wasm e2e, without the full
# ~250s gate, when iterating on the wasm surface.
#
# It builds the `-Dwasm` ReleaseSafe binary ONCE (ADR-0132: never a bare
# `zig build -Dwasm` = Debug), then runs the wasm e2e against that shared binary
# (CLJW_SKIP_BUILD=1 so each script reuses it instead of rebuilding mid-run and
# clobbering it). On a host without the zwasm sibling it skips cleanly (exit 0).
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -d ../zwasm_from_scratch ]; then
    echo "SKIP wasm gate: ../zwasm_from_scratch not present"
    exit 0
fi

echo "==> Building -Dwasm ReleaseSafe binary (once)"
if ! zig build -Dwasm -Doptimize=ReleaseSafe -Dcpu=baseline >/dev/null 2>&1; then
    echo "FAIL: zig build -Dwasm failed (zwasm relative-path consume broken?)" >&2
    exit 1
fi
zig-out/bin/cljw --version
# Assert the binary is ACTUALLY wasm-enabled: `b.lazyDependency("zwasm")` can
# silently leave build_options.wasm=false (fetch pending / dep unresolved), and
# then `--version` says `(ReleaseSafe)` with no `wasm`. The whole gate needs this
# -Dwasm binary to STAY put — CLJW_SKIP_BUILD makes the e2e reuse it (never
# rebuild → never revert to non-wasm), mirroring ADR-0132's "don't let the shared
# binary become the wrong thing" backstop, for the wasm variant.
zig-out/bin/cljw --version | grep -q 'wasm' || {
    echo "FAIL: built binary is NOT wasm-enabled (zwasm dep did not resolve): $(zig-out/bin/cljw --version)" >&2
    exit 1
}

export CLJW_SKIP_BUILD=1 CLJW_OPT=ReleaseSafe
rc=0
for s in phase16_wasm_ffi phase16_wasm_run; do
    echo "==> $s"
    if bash "test/e2e/$s.sh"; then
        echo "    [pass] $s"
    else
        echo "    [FAIL] $s" >&2
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "WASM GATE: all green"
else
    echo "WASM GATE: FAILURES (see above)" >&2
fi
exit "$rc"
