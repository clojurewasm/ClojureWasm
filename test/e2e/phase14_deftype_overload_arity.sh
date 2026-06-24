#!/usr/bin/env bash
# test/e2e/phase14_deftype_overload_arity.sh — D-530: a deftype/defrecord may
# implement the same method NAME at different arities across DIFFERENT protocol
# sections (clojure.lang.Seqable `seq[this]` + clojure.lang.Sorted
# `seq[this asc]`). clj allows this (NewInstanceMethod keys by [name, arity]);
# cljw previously lowered each section to its own single-arity entry, so
# `(. inst seq true)` resolved the arity-1 Seqable row → "Wrong number of args
# (2)…expected 1". The lowering now merges cross-section same-name arities into
# one multi-arity fn registered under each contributing protocol; `selectMethod`
# dispatches by arg count. All expected values oracle-verified against clj.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# 1. The core case — Seqable seq[this] + Sorted seq[this asc] on one deftype.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [v]
  clojure.lang.Seqable
  (seq [this] (list :one v))
  clojure.lang.Sorted
  (seq [this ascending] (list :two v ascending)))
(def t (T. 42))
(print [(seq t) (. t seq true)])
EOF
)
assert_eq "deftype_seq_overload" "$got" "[(:one 42) (:two 42 true)]"

# 2. The dot-form 2-arity AND the protocol-fn 1-arity both reach the right body.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [v]
  clojure.lang.Seqable
  (seq [this] :arity-1)
  clojure.lang.Sorted
  (seq [this asc] [:arity-2 asc]))
(def t (T. 0))
(print [(seq t) (.seq t false) (. t seq true)])
EOF
)
assert_eq "deftype_seq_both_paths" "$got" "[:arity-1 [:arity-2 false] [:arity-2 true]]"

# 3. defrecord shares lowerDefType — the same cross-section merge must apply.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord R [v]
  clojure.lang.Seqable
  (seq [this] (list :r1 v))
  clojure.lang.Sorted
  (seq [this ascending] (list :r2 ascending)))
(def r (R. 7))
(print [(seq r) (. r seq false)])
EOF
)
assert_eq "defrecord_seq_overload" "$got" "[(:r1 7) (:r2 false)]"

# 4. Within-section multi-arity (D-279) must keep working unchanged — a method
#    with two arities in ONE section, alongside an unrelated cross-section name.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype L [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  (valAt [this k nf] (get m k nf)))
(def l (L. {:a 1}))
(print [(.valAt l :a) (.valAt l :z 99)])
EOF
)
assert_eq "within_section_multi_arity" "$got" "[1 99]"

# 5. reify shares the cross-section gap + fix (expandReify, same concept). clj
#    allows the overload on reify too; bodies return ISeqs so clj's Seqable.seq
#    ISeq-return contract is satisfied (cljw does not enforce host return types).
got=$("$BIN" - <<'EOF' 2>/dev/null
(def r (reify
         clojure.lang.Seqable (seq [this] (list :a1))
         clojure.lang.Sorted (seq [this asc] (list :a2 asc))))
(print [(. r seq) (. r seq true)])
EOF
)
assert_eq "reify_seq_overload" "$got" "[(:a1) (:a2 true)]"

# 6. Real data.priority-map subseq/rsubseq — the use case that drove D-530.
PM="$HOME/Documents/OSS/data.priority-map"
if [ -d "$PM" ]; then
  PROJ="$(mktemp -d)"
  printf '{:deps {org.clojure/data.priority-map {:local/root "%s"}}}\n' "$PM" > "$PROJ/deps.edn"
  got=$(cd "$PROJ" && timeout 40 "$OLDPWD/$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.data.priority-map :as pm])
(def p (pm/priority-map :a 3 :b 1 :c 2 :d 4))
(print [(subseq p < 3) (rsubseq p > 1)])
EOF
)
  rm -rf "$PROJ"
  assert_eq "priority_map_subseq" "$got" "[([:b 1] [:c 2]) ([:d 4] [:a 3] [:c 2])]"
else
  echo "SKIP priority_map_subseq (data.priority-map not cloned at $PM)"
fi

echo "ALL phase14_deftype_overload_arity PASS"
