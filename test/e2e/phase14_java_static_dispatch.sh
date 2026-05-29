#!/usr/bin/env bash
# test/e2e/phase14_java_static_dispatch.sh
#
# Phase 14 §9.16 — D-121 Java static method dispatch + ADR-0050
# unified InteropCallNode. Covers the 4 dispatch kinds:
#   - .static_method    : (java.util.UUID/randomUUID),
#                         (java.lang.System/currentTimeMillis)
#   - .constructor      : (java.io.File. "/tmp/x.txt")
#   - .instance_member  : (.path file)  [field-first via op_method_call;
#                         op_field_access retired in ADR-0050 am1]
#   - error path        : unresolved class + unknown method on resolved class
#
# Confirms `resolveJavaSurface` closes the cljw-prefix gap that
# previously made `(java.io.File. "x")` raise symbol_unresolved.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

# --- Case 1: (java.util.UUID/randomUUID) → 36-char canonical UUID ---
out=$("$BIN" -e '(java.util.UUID/randomUUID)' 2>&1 | tail -n 1)
# nil result + UUID value; the value lands on its own line. Use length
# check (36) to avoid the nondeterminism of UUID bytes.
len=$(printf '%s' "$out" | wc -c | tr -d ' ')
[[ "$len" -ge 36 ]] || fail "uuid_randomUUID: expected ≥ 36 chars, got '$out' (len=$len)"
echo "PASS uuid_randomUUID -> 36+ char UUID"

# --- Case 2: (java.lang.System/currentTimeMillis) > 0 ---
out=$("$BIN" -e '(> (java.lang.System/currentTimeMillis) 0)' 2>&1 | tail -n 1)
[[ "$out" == 'true' ]] || fail "system_currentTimeMillis: expected 'true', got '$out'"
echo "PASS system_currentTimeMillis -> true"

# --- Case 3: (java.lang.System/nanoTime) is positive. Returned as a
#     Float because typical nanoTime values exceed i48 range and
#     `Value.initInteger` falls back to Float per F-005 — confirm via
#     `pos?` semantics rather than integer? to allow either tag. ---
out=$("$BIN" -e '(> (java.lang.System/nanoTime) 0)' 2>&1 | tail -n 1)
[[ "$out" == 'true' ]] || fail "system_nanoTime: expected 'true', got '$out'"
echo "PASS system_nanoTime -> > 0 true"

# --- Case 4: (java.io.File. path) returns a value carrying .path ---
out=$("$BIN" -e '(.path (java.io.File. "/tmp/x.txt"))' 2>&1 | tail -n 1)
[[ "$out" == '"/tmp/x.txt"' ]] || fail "file_ctor_path: expected '\"/tmp/x.txt\"', got '$out'"
echo "PASS file_ctor_path -> /tmp/x.txt"

# --- Case 5: unresolved class falls through to symbol_unresolved ---
set +e
out=$("$BIN" -e '(unknown.Pkg/someMethod)' 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "unresolved_class: expected non-zero exit"
case "$out" in
    *"unknown.Pkg"*|*"unresolved"*|*"No namespace"*)
        echo "PASS unresolved_class -> error mentioning unknown.Pkg" ;;
    *)
        fail "unresolved_class: expected diagnostic mentioning the unresolved namespace, got '$out'" ;;
esac

# --- Case 6: resolved class + unknown method falls through to call ---
set +e
out=$("$BIN" -e '(java.util.UUID/nonexistentMethod)' 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "unknown_method: expected non-zero exit"
case "$out" in
    *"java.util.UUID"*|*"unresolved"*|*"No namespace"*|*"nonexistentMethod"*)
        echo "PASS unknown_method -> error mentioning the call" ;;
    *)
        fail "unknown_method: expected diagnostic, got '$out'" ;;
esac

echo "ALL PASS phase14_java_static_dispatch"
