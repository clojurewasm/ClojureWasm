#!/usr/bin/env bash
# test/e2e/phase8_compare_cli.sh
#
# Phase 8 §9.10 row 8.4 — `cljw --compare` CLI flag end-to-end.
# Per ADR-0005 + ADR-0044 full-bench remit (ADR-0044 = bench schema,
# was ADR-0027 pre-audit; renumbered Phase 8 → 9): runs source through
# BOTH backends in isolated runtimes + prints `OK <value/error>` when
# value/error and stdout agree, `MISMATCH` (exit 1) on divergence.

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

# --- arithmetic / let / fn parity ---
got=$("$BIN" --compare -e '(+ 1 2 3)' 2>/dev/null)
assert_eq 'arith_parity' "$got" 'OK 6'

got=$("$BIN" --compare -e '(let* [x 10] (* x x))' 2>/dev/null)
assert_eq 'let_parity' "$got" 'OK 100'

got=$("$BIN" --compare -e '((fn* [a b] (+ a b)) 7 8)' 2>/dev/null)
assert_eq 'fn_parity' "$got" 'OK 15'

# --- try/catch parity (row 7.11 host_class hierarchy) ---
got=$("$BIN" --compare -e '(try (throw (ex-info "x" {})) (catch RuntimeException e 99))' 2>/dev/null)
assert_eq 'catch_runtime_parity' "$got" 'OK 99'

# --- apply variadic parity (row 7.9 ADR-0042) ---
got=$("$BIN" --compare -e "(apply + 1 2 '(3 4 5))" 2>/dev/null)
assert_eq 'apply_variadic_parity' "$got" 'OK 15'

# --- defrecord + .method parity (row 7.6 + 7.12) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(defprotocol IShift (shift-by [this n]))
(defrecord Box [v] IShift (shift-by [self n] (+ (.v self) n)))
(.shift-by (->Box 10) 5)
EOF
)
assert_eq 'defrecord_methodcall_parity' "$got" 'OK 15'

# --- classpath reaches both isolated backends; agreed stdout emits once ---
PROBE_CP="test/e2e/fixtures/compare"
expected_probe=$'case-1|\nvalue 3\nPROBE-MAIN-DONE\nOK nil'

got=$("$BIN" --compare -cp "$PROBE_CP" -e "(require 'probe.main) (probe.main/report)" 2>/dev/null)
assert_eq 'classpath_require_parity' "$got" "$expected_probe"

# --- --compare must remain live after -m switches into the run-mode grammar ---
got=$("$BIN" --compare -cp "$PROBE_CP" -m probe.main 2>/dev/null)
assert_eq 'main_mode_parity' "$got" "$expected_probe"

# --- identical failures are agreement, with a successful process exit ---
got=$("$BIN" --compare -e '(/ 1 0)' 2>&1)
assert_eq 'identical_error_parity' "$got" 'OK ERROR ArithmeticError'

echo
echo "Phase 8 row 8.4 --compare CLI e2e: all green."
