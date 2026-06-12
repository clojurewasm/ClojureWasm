#!/usr/bin/env bash
# test/e2e/phase14_deftype_imeta.sh — clojure.lang.IMeta as a recognised deftype
# host-supertype marker (D-280 family / D-271 IObj-IMeta). clj's IObj EXTENDS
# IMeta: withMeta lives on IObj, the read-only `meta` on IMeta. cljw recognised
# IObj (meta + withMeta) but NOT IMeta, so a deftype declaring IMeta separately
# (instaparse's AutoFlattenSeq: IObj withMeta + IMeta meta) failed to define.
# IMeta is a protocol_remap mirroring IObj's `meta` → IObj/-meta. Load-level
# (the deftype defines + dispatches the method), matching the IObj status. Layer 2.
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

# a deftype declaring IMeta alone defines + constructs (the instaparse blocker)
assert_eq 'imeta-defines' \
  "$(run '(deftype Box [v] clojure.lang.IMeta (meta [self] {:t :box})) (prn (instance? Box (Box. 1)))')" 'true'
# the instaparse shape: IObj (withMeta) + IMeta (meta) on one deftype
assert_eq 'iobj-plus-imeta' \
  "$(run '(deftype B [v] clojure.lang.IObj (withMeta [self m] (B. v)) clojure.lang.IMeta (meta [self] {:t :b})) (prn (instance? B (B. 9)))')" 'true'

echo "OK — phase14_deftype_imeta green"
