#!/usr/bin/env bash
# test/e2e/phase15_ns_binding_roundtrip.sh — *ns*/current_ns binding round-trip
# (ADR-0085 Commit 1, D-232). `current_ns` is a materialised view of `*ns*`:
# `(binding [*ns* *ns*] (in-ns 'tmp) …)` rebinds the *ns* thread binding (not
# the root), and on frame pop `current_ns` restores to the outer ns — so the
# NEXT top-level form resolves there again. This is the prerequisite for
# clojure.test-helper's temp-ns / eval-in-temp-ns. clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# inside the binding the ns is the temp ns; after pop it restores to user
assert_eq 'inside-and-restore' \
  "$("$BIN" -e '(def b (ns-name *ns*)) (def inside (binding [*ns* *ns*] (in-ns (quote tmp.x)) (ns-name *ns*))) [inside (ns-name *ns*) b]' 2>&1 | tail -1)" \
  '[tmp.x user user]'

# after the binding pops, a clojure.core fn resolves again in the restored ns
# (it would be unresolved if current_ns were left at the bare temp ns)
assert_eq 'core-resolves-after' \
  "$("$BIN" -e '(binding [*ns* *ns*] (in-ns (quote tmp.y))) (inc 41)' 2>&1 | tail -1)" \
  '42'

# nested binding round-trips through both levels
assert_eq 'nested-roundtrip' \
  "$("$BIN" -e '(binding [*ns* *ns*] (in-ns (quote a)) (binding [*ns* *ns*] (in-ns (quote b)))) (ns-name *ns*)' 2>&1 | tail -1)" \
  'user'

echo "OK — phase15_ns_binding_roundtrip (3 cases) green"
