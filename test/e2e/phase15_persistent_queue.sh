#!/usr/bin/env bash
# test/e2e/phase15_persistent_queue.sh — clojure.lang.PersistentQueue (ADR-0087).
# The reader-round-trippable `#queue (…)` print form is the AD-012 pin (clj
# prints an opaque non-reproducible #object). FIFO semantics + equality are
# corpus-verified against clj (test/diff/clj_corpus/persistent_queue.txt); this
# layer locks the cljw-specific print + reader round-trip. `cljw -e` echoes each
# top-level form's value, so a bare queue value renders via its printValue. L2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# AD-012: readable #queue (…) print (clj: opaque #object).
assert_eq 'print_nonempty' "$("$BIN" -e '(conj clojure.lang.PersistentQueue/EMPTY 1 2 3)' 2>&1 | tail -1)" '#queue (1 2 3)'
assert_eq 'print_empty'    "$("$BIN" -e 'clojure.lang.PersistentQueue/EMPTY' 2>&1 | tail -1)"               '#queue ()'

# #queue data-reader round-trip (cljw extension — clj has no #queue reader).
assert_eq 'reader_rt'   "$("$BIN" -e '(read-string "#queue (1 2 3)")' 2>&1 | tail -1)" '#queue (1 2 3)'
assert_eq 'reader_q'    "$("$BIN" -e '(queue? (read-string "#queue (1 2 3)"))' 2>&1 | tail -1)" 'true'

# class + queue? predicate
assert_eq 'class'       "$("$BIN" -e '(= clojure.lang.PersistentQueue (class (conj clojure.lang.PersistentQueue/EMPTY 1)))' 2>&1 | tail -1)" 'true'
assert_eq 'queue_pred'  "$("$BIN" -e '[(queue? clojure.lang.PersistentQueue/EMPTY) (queue? [1]) (queue? nil)]' 2>&1 | tail -1)" '[true false false]'

echo "OK — phase15_persistent_queue (6 cases) green"
