#!/usr/bin/env bash
# test/e2e/phase14_deftype_sorted.sh — clojure.lang.Sorted deftype dispatch.
# clj's subseq/rsubseq (core.clj) drive ANY Sorted via .comparator/.entryKey/
# .seqFrom/.seq-2arity; cljw's subseq primitive previously accepted only the
# native sorted_map/sorted_set tags, so a Sorted deftype (data.priority-map)
# raised Type error. The Sorted protocol_remap (D-280d4) registers the methods;
# this validates the primitive consults them, mirroring clj's bound algebra.
# All expected values oracle-verified against clj 2026-06-13.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# A minimal Sorted deftype over a backing native sorted-map — the same method
# shapes data.priority-map declares. `.comparator` on the NATIVE sorted-map is
# part of the surface under test (clj PersistentTreeMap.comparator()).
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype SM [m]
  clojure.lang.Sorted
  (comparator [_] (.comparator m))
  (entryKey [_ e] (key e))
  (seq [_ ascending] (if ascending (seq m) (rseq m)))
  (seqFrom [_ k ascending] (if ascending (subseq m >= k) (rsubseq m <= k)))
  clojure.lang.Seqable
  (seq [_] (seq m)))
(def sm (->SM (sorted-map 1 :a 2 :b 3 :c)))
(prn (subseq sm >= 2))
(prn (subseq sm > 1))
(prn (subseq sm < 3))
(prn (subseq sm <= 1))
(prn (rsubseq sm > 1))
(prn (rsubseq sm <= 2))
(prn (subseq sm > 1 <= 2))
(prn (subseq sm >= 1 < 3))
(prn (subseq sm > 5))
(prn (rsubseq sm < 1))
EOF
) || true
want='([2 :b] [3 :c])
([2 :b] [3 :c])
([1 :a] [2 :b])
([1 :a])
([3 :c] [2 :b])
([2 :b] [1 :a])
([2 :b])
([1 :a] [2 :b])
nil
nil'
assert_eq 'sorted_deftype_subseq' "$got" "$want"

# .comparator on the native sorted colls directly: default → the compare fn
# (callable); custom (sorted-map-by) → the user fn itself.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn ((.comparator (sorted-map 1 :a)) 1 2))
(def cmp-desc (fn [a b] (compare b a)))
(prn (identical? cmp-desc (.comparator (sorted-map-by cmp-desc 1 :a))))
(prn ((.comparator (sorted-set 2 1)) 3 1))
EOF
) || true
want='-1
true
1'
assert_eq 'native_comparator_dotcall' "$got" "$want"

echo "OK — phase14_deftype_sorted (2 cases) green"
