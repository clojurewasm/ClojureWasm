#!/usr/bin/env bash
# test/e2e/phase14_reify_metadata.sh — reify instances are IObj/IMeta + metable
# (ADR-0134 value-driven slice, reify pulled by clojure.spec.alpha, whose with-name
# attaches ::name metadata to every spec object). clj's reify ALWAYS implements
# IObj; cljw previously raised "cannot attach metadata to reified_instance". A plain
# deftype is NOT auto-IObj (stays the typed_instance error) — that asymmetry is clj's
# and is preserved. Layer 2.
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

PRE='(defprotocol P (m [s]))'

assert_eq 'reify-is-iobj' \
  "$(run "$PRE (prn (instance? clojure.lang.IObj (reify P (m [_] 1))))")" 'true'

assert_eq 'reify-is-imeta' \
  "$(run "$PRE (prn (instance? clojure.lang.IMeta (reify P (m [_] 1))))")" 'true'

assert_eq 'reify-with-meta-roundtrip' \
  "$(run "$PRE (prn (meta (with-meta (reify P (m [_] 1)) {:a 1})))")" '{:a 1}'

# method still dispatches on the meta-bearing copy (descriptor shared)
assert_eq 'reify-meta-method-works' \
  "$(run "$PRE (prn (m (with-meta (reify P (m [_] 42)) {:a 1})))")" '42'

# with-meta mints a fresh instance (clj parity)
assert_eq 'reify-with-meta-not-identical' \
  "$(run "$PRE (def r (reify P (m [_] 1))) (prn (identical? r (with-meta r {:a 1})))")" 'false'

# fresh reify has nil meta
assert_eq 'reify-fresh-meta-nil' \
  "$(run "$PRE (prn (meta (reify P (m [_] 1))))")" 'nil'

# plain deftype is NOT auto-IObj (clj asymmetry preserved)
assert_eq 'deftype-not-iobj' \
  "$(run '(deftype T []) (prn (instance? clojure.lang.IObj (->T)))')" 'false'
