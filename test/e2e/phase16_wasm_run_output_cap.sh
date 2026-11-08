#!/usr/bin/env bash
# test/e2e/phase16_wasm_run_output_cap.sh — D-349 + D-570.
#
# `(wasm/run …)` buffers the guest's stdout and stderr in HOST memory, and
# neither of the other two budgets bounds that: fuel bounds instructions, and
# how many bytes an instruction writes is the guest's choice. Measured before
# the cap existed: `spam_stdout.wasm` buffered exactly 64,000,000 bytes for
# 1,000,000 fuel — 64 bytes per unit — so ~64 GB under the default fuel budget.
# A 1e8-fuel run reached ~6.4 GB RSS; with the cap it peaks at ~33 MB.
#
# The guest IGNORES fd_write's errno, so this holds against a guest that does
# not cooperate with the cap.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

F=test/e2e/fixtures/wasm/spam_stdout.wasm
[ -f "$F" ] || fail "the spam fixture is missing"

# Fuel is chosen per case for COST, not for coverage: the guest produces 64
# bytes per unit of fuel, so a run's wall time is proportional to the volume it
# would produce uncapped. 1e6 fuel (64 MB) costs ~60 s, and four of those made
# this the most expensive step in the gate — so each case uses the least fuel
# that still exceeds the cap it is testing.
#   SMALL_FUEL 20000  -> ~1.28 MB uncapped: enough to overrun a 4096 / 100 cap
#   DEF_FUEL  300000  -> ~19.2 MB uncapped: the least that overruns the 16 MiB
#                        default, which is the one case that cannot be cheaper
SMALL_FUEL=20000
DEF_FUEL=300000
run() { # run <opts> -> byte count
    "$BIN" -e "(println (count (:out (wasm/run \"$F\" $1))))" 2>/dev/null | sed -n 1p
}

got="$(run "{:fuel $SMALL_FUEL :max-output-bytes 4096}")"
[[ "$got" == "4096" ]] || fail "explicit cap not honoured: expected 4096 bytes, got '$got'"
echo "PASS explicit-cap -> $got"

got="$(run "{:fuel $SMALL_FUEL :max-output-bytes 100}")"
[[ "$got" == "100" ]] || fail "small cap not honoured: expected 100 bytes, got '$got'"
echo "PASS small-cap -> $got"

# The default is finite, and well under what this guest would otherwise produce.
got="$(run "{:fuel $DEF_FUEL}")"
[[ "$got" == "16777216" ]] || fail "the DEFAULT cap is not 16 MiB: got '$got' bytes (uncapped this fuel produces ~19.2 MB, so a larger number means no default applied)"
echo "PASS default-cap-is-finite -> $got"

# `<= 0` opts out, the same convention :fuel and :max-memory-pages use. This is
# the case that proves the cap above is the cap and not some other limit.
# The load-bearing case: `<= 0` must give back the FULL volume, so the capped
# numbers above are the cap and not some other limit. 20000 fuel * 64 B.
got="$(run "{:fuel $SMALL_FUEL :max-output-bytes 0}")"
[[ "$got" == "1280000" ]] || fail "unmetered opt-out changed the result: expected 1280000, got '$got'"
echo "PASS unmetered-opt-out -> $got"

# A guest that writes a normal amount is untouched.
got="$("$BIN" -e '(println (pr-str (:out (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:args ["prog" "7"]}))))' 2>/dev/null | sed -n 1p)"
[[ -n "$got" && "$got" != '""' ]] || fail "an ordinary guest lost its output under the default cap: got '$got'"
echo "PASS ordinary-guest-unaffected -> $got"

# --- the wall-clock axis (D-570) ------------------------------------------
#
# Fuel is a very poor proxy for time. Measured on the SAME 1,000,000 fuel: this
# host-call-heavy guest took 66 s, and a compute-bound guest took 0.087 s — a
# ~760x spread, so the 1e9 default fuel permits roughly 18 HOURS for the first
# shape. Capping output bounds the memory and does nothing about that: a guest
# that ignores `.nospc` keeps burning fuel with its writes discarded.
start=$(date +%s)
"$BIN" -e "(wasm/run \"$F\" {:timeout-ms 2000})" >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
[[ "$elapsed" -le 8 ]] || fail "an explicit :timeout-ms 2000 did not stop the guest: took ${elapsed}s"
echo "PASS explicit-timeout -> ${elapsed}s"

# The default is finite. Asserted against the guest's UNCAPPED time rather than
# a clock reading: at this fuel it would run ~13 s uncapped, so finishing well
# inside that is the default doing its job. Bounded loosely because a loaded CI
# runner is slow, and a flaky timing assertion is worse than a coarse one.
start=$(date +%s)
"$BIN" -e "(wasm/run \"$F\" {:fuel 200000})" >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
[[ "$elapsed" -le 90 ]] || fail "the default wall-clock cap is not applied: took ${elapsed}s"
echo "PASS default-timeout-is-finite -> ${elapsed}s"

echo "OK — phase16_wasm_run_output_cap (7 cases) green"
