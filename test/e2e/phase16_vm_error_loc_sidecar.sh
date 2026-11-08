#!/usr/bin/env bash
# e2e-process-boundary: asserts the line:col and source window in the CLI's rendered stderr for an uncaught error
# test/e2e/phase16_vm_error_loc_sidecar.sh
#
# ADR-0173 C1 guard: the per-instruction source loc moved from the
# executed instruction record into a parallel sidecar (WireInstr +
# InstrLoc, split at compiler finalize). The silent failure mode of a
# sidecar is locs off-by-N after a stream-SHRINKING pass — the error
# then reports a WRONG line, which value-comparing tests (the diff
# oracle) can never catch. This e2e pins the EXACT line:col of a VM
# error raised:
#   - AFTER a peephole-elided region (`:discarded` in statement
#     position = pure-push + op_pop, physically removed), and
#   - AFTER a fused compare-branch (`(if (< x 10) …)`).
# If the loc sidecar ever drifts from the instruction stream, the
# asserted 5:6 moves and this test fails loudly (ADR-0118 contract).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/loc_fixture.clj" <<'EOF'
(defn f [x]
  (do
    :discarded
    (if (< x 10)
      (nth [1 2] 5)
      :big)))
(f 1)
EOF

# --- Case 1: exact line:col after peephole elision + fused compare-branch ---
out=$("$BIN" "$TMP/loc_fixture.clj" 2>&1 || true)
case "$out" in
    *"loc_fixture.clj:5:6"*"nth: index out of range"*)
        echo "PASS vm_error_loc_after_peephole_and_fusion -> 5:6 exact" ;;
    *)
        fail "vm_error_loc_after_peephole_and_fusion: expected loc_fixture.clj:5:6; got '$out'" ;;
esac

# --- Case 2: the caret context window names the erroring source line ---
case "$out" in
    *"(nth [1 2] 5)"*)
        echo "PASS vm_error_loc_source_window -> erroring line rendered" ;;
    *)
        fail "vm_error_loc_source_window: expected '(nth [1 2] 5)' in context; got '$out'" ;;
esac

echo "phase16_vm_error_loc_sidecar: all cases passed"
