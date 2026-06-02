#!/usr/bin/env bash
# scripts/check_vm_parity.sh — VM-backend parity probe (ADR-0070 / D-196).
#
# Builds cljw with `-Dbackend=vm` (ReleaseSafe, matching the e2e gate + the
# production-distribution config) and runs the clj-grounded corpus + the D-196
# VM-parity-blocker e2e against it, reporting the failing count. This is the
# mechanism that stops VM gaps from being MASKED by the tree_walk default (the
# per-commit gate runs e2e on tree_walk only; VM is otherwise covered by unit +
# diff_test alone). Informational while D-196 is open; on D-196 close it is
# promoted to a hard per-commit gate and build.zig flips its default to `vm`.
#
# The probe lists the D-196 blocker e2e EXPLICITLY (not a glob): a broad
# phase14 glob proved unreliable here (some sibling e2e perturbed the shared
# binary mid-run). As each blocker is closed, drop it from BLOCKERS; when the
# list is empty + corpus green, the flip lands.
#
# Restores the default (tree_walk ReleaseSafe) binary on exit.
# Usage: bash scripts/check_vm_parity.sh   # exit 0 = all green; N = N failing.

set -uo pipefail
cd "$(dirname "$0")/.."

# D-196 blocker e2e (basename under test/e2e/, minus .sh). Prune as gaps close.
BLOCKERS=(
    phase14_ns_directive           # (ns …) :refer-clojure filter (VM-DEFER D-098)
    # phase14_java_static_dispatch CLOSED 2026-06-02 (D-196 blocker 3): the
    # java-surface ctor `(java.io.File. …)` now resolves on the VM via the
    # shared special_forms.constructInstance (was deftype-only). Pruned.
    # phase14_catch_keyword CLOSED 2026-06-02 (D-014b VM lowering):
    # op_match_type_keyword parallels op_match_class. Pruned.
    # phase14_with_context + phase14_user_throw CLOSED 2026-06-02 (ADR-0071):
    # the cleanup-handler kind (op_push_cleanup / op_reraise) preserves the
    # dynamic error-context + catalog Kind through a binding / bare-try
    # unwind, matching TreeWalk's `defer`. Pruned from the blocker list.
    # NOTE: phase14_eval is NOT a VM blocker — `eval` is unimplemented on BOTH
    # backends (name_error), tracked separately as D-197. Do not add here.
)

restore() { zig build -Doptimize=ReleaseSafe >/dev/null 2>&1 || true; }
trap restore EXIT

echo "check_vm_parity: building -Dbackend=vm -Doptimize=ReleaseSafe…"
if ! zig build -Doptimize=ReleaseSafe -Dbackend=vm >/tmp/vmp_build.txt 2>&1; then
    echo "check_vm_parity: VM BUILD FAILED (see /tmp/vmp_build.txt)"; exit 1
fi
export CLJW_SKIP_BUILD=1

fails=0
if bash scripts/check_corpus_regression.sh >/tmp/vmp_corpus.txt 2>&1; then
    echo "  corpus       : ok  ($(tail -1 /tmp/vmp_corpus.txt))"
else
    echo "  corpus       : FAIL ($(tail -1 /tmp/vmp_corpus.txt))"; fails=$((fails + 1))
fi

for name in "${BLOCKERS[@]}"; do
    t="test/e2e/$name.sh"
    [ -f "$t" ] || { echo "  MISSING      : $name"; continue; }
    if timeout 120 bash "$t" >/tmp/vmp_e2e.txt 2>&1; then
        echo "  CLOSED       : $name  (passes on VM — prune from BLOCKERS)"
    else
        echo "  blocker      : $name  ($(grep -iE 'FAIL|NotImplemented' /tmp/vmp_e2e.txt | head -1 | cut -c1-80))"
        fails=$((fails + 1))
    fi
done

echo "check_vm_parity: $fails failing group(s) over corpus + ${#BLOCKERS[@]} D-196 blockers on -Dbackend=vm"
exit "$fails"
