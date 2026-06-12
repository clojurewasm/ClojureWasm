#!/usr/bin/env bash
# test/e2e/phase14_json_options.sh — clojure.data.json read-str/write-str options
# (D-401). cljw's bundled read-str/write-str were 1-arity (the `:key-fn` follow-up
# noted in json.zig:22). clj's `(read-str s :key-fn keyword)` keywordizes object
# keys; `(write-str m :key-fn name)` stringifies them. Implemented as a Clojure
# wrapper (json.clj) over the raw -read-str-impl/-write-str-impl primitives,
# applying :key-fn/:value-fn via clojure.walk. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
(require '[clojure.data.json :as json])
$1
EOF
}

# read-str :key-fn keyword → keyword keys
assert_eq 'read-key-fn'   "$(run '(prn (json/read-str "{\"a\":[1,2],\"b\":3}" :key-fn keyword))')"  '{:a [1 2], :b 3}'
# read-str default (no opts) → string keys (unchanged)
assert_eq 'read-default'  "$(run '(prn (json/read-str "{\"a\":1}"))')"                                '{"a" 1}'
# read-str :value-fn → transform values by (key, value)
assert_eq 'read-value-fn' "$(run '(prn (json/read-str "{\"a\":1,\"b\":2}" :key-fn keyword :value-fn (fn [k v] (inc v))))')"  '{:a 2, :b 3}'
# write-str :key-fn name → string keys from keyword map
assert_eq 'write-key-fn'  "$(run '(prn (json/write-str {:a 1 :b 2} :key-fn name))')"                 '"{\"a\":1,\"b\":2}"'
# write-str default still works (1-arity)
assert_eq 'write-default' "$(run '(prn (json/write-str [1 2 3]))')"                                  '"[1,2,3]"'

echo "OK — phase14_json_options (5 cases) green"
