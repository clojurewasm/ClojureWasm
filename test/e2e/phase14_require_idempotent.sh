#!/usr/bin/env bash
# test/e2e/phase14_require_idempotent.sh — ADR-0163 commit 2: loadOrFindNs keys
# "already loaded" off rt.loaded_libs, NOT mappings.count(). The eager bootstrap
# pre-registers its namespaces in loaded_libs (markFilesLoaded), so (require 'eager-ns)
# is a true no-op: it does NOT re-parse the embedded source, which would rebind every
# var to a fresh identity. This guards the pre-register prerequisite — without it the
# new guard would re-load an already-eager ns on every require.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
$1
EOF
}

# Capture a var's root, require its eager ns, re-resolve: a no-op require leaves the
# SAME function object (identical?); a re-load would rebind it to a fresh one.
# An EAGER ns (clojure.string, in EAGER_NS): usable without require; a re-require is a no-op.
assert_eq 'eager-noreload' \
  "$(run '(def v clojure.string/upper-case) (require (quote [clojure.string])) (prn (identical? v clojure.string/upper-case))')" \
  'true'
# A LAZY ns (clojure.set): the FIRST require loads it; a SECOND require is a no-op (no re-load,
# so the var identity is stable). require-first because the var is unresolvable before loading.
assert_eq 'lazy-noreload' \
  "$(run '(require (quote [clojure.set])) (def v clojure.set/union) (require (quote [clojure.set])) (prn (identical? v clojure.set/union))')" \
  'true'
# A bundled lib that gained a :require in commit 1 (clojure.test -> string/walk) loads
# clean under the new guard (a missing/re-loading dep would error before :loaded prints).
assert_eq 'test-loads' \
  "$(run '(require (quote [clojure.test])) (prn :loaded)')" \
  ':loaded'

echo "OK — phase14_require_idempotent (3 cases) green"
