#!/usr/bin/env bash
# test/e2e/phase13_exit_smoke.sh
#
# §9.15 row 13.5 — Phase 13 exit smoke + final activation verify.
# Asserts:
#   - STM Ref + read-only `deref` work end-to-end (rows 13.1 + 13.2)
#   - A Ref correctly holds a heap value through the GC trace path
#   - Peephole (ADR-0047, row 13.3) preserves observable semantics
#   - 5-canonical fib_recursive(25) workload completes (row 13.4
#     locked v0 24C.10 = 24 ms warm; cljw measured 20 ms = 83%, ✓
#     within 110% — this case verifies *execution*, not perf)
#
# No `build_options.phase_at_least_13` flag — per row 13.5 wording,
# the flag is minted only if a phase-gated behaviour surfaced. Ref
# and peephole are unconditionally active; neither needs a phase
# gate, so no flag flip lands.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- (1) Ref + deref read-only path (rows 13.1 + 13.2) ---
got=$("$BIN" -e '(deref (ref 5))' 2>/dev/null) || fail "(1): non-zero exit"
assert_eq 'ref_deref_int' "$got" '5'

# --- (2) Ref holds a heap value — GC trace path crossed ---
got=$("$BIN" -e '(deref (ref [1 2 3]))' 2>/dev/null) || fail "(2): non-zero exit"
assert_eq 'ref_deref_vector' "$got" '[1 2 3]'

# --- (3) Peephole pure-push + op_pop elision (row 13.3, ADR-0047) ---
got=$("$BIN" -e '(do 1 2 3)' 2>/dev/null) || fail "(3): non-zero exit"
assert_eq 'peephole_do_chain' "$got" '3'

# --- (4) Peephole + Ref composed (peephole inside a Ref's seed expr) ---
got=$("$BIN" -e '(deref (ref (do 1 2 3)))' 2>/dev/null) || fail "(4): non-zero exit"
assert_eq 'ref_holds_do_chain' "$got" '3'

# --- (5) 5-canonical fib_recursive(25) executes (row 13.4) ---
got=$("$BIN" -e '(do (defn fib [n] (if (<= n 1) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 25))' 2>/dev/null) || fail "(5): non-zero exit"
assert_eq 'fib_recursive_25' "$got" '75025'

echo "ALL PASS — Phase 13 exit smoke green"
