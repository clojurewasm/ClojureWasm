#!/usr/bin/env bash
# test/e2e/phase14_destructure.sh
#
# §A26 coverage-floor — D-076 destructuring cycle 1: SEQUENTIAL vector
# patterns in `let`, lowered to plain-symbol let* + nth/nthnext at the
# macro layer (expandLet, JVM clojure.core/destructure shape).
#
# Validates: [a b] / [a b & rest] / [a b :as all] / nested / missing→nil
# / sequential-dependency / the all-symbols fast path (zero regression).
# Associative {:keys}, fn-param, and loop* destructuring are deferred
# (D-076 follow-up) and raise a clear error — checked here too.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'seq_basic'   "$("$BIN" -e '(let [[a b] [1 2]] (+ a b))')"            '3'
assert_eq 'seq_rest'    "$("$BIN" -e '(let [[a b & r] [1 2 3 4]] r)')"          '(3 4)'
assert_eq 'seq_as'      "$("$BIN" -e '(let [[a b :as all] [1 2]] all)')"        '[1 2]'
assert_eq 'seq_nested'  "$("$BIN" -e '(let [[[a b] c] [[1 2] 3]] (+ a b c))')"  '6'
assert_eq 'seq_missing' "$("$BIN" -e '(let [[a b] [1]] b)')"                    'nil'
assert_eq 'seq_depends' "$("$BIN" -e '(let [[a b] [1 2] c (+ a b)] c)')"        '3'
assert_eq 'seq_rest_only' "$("$BIN" -e '(let [[& r] [1 2 3]] r)')"             '(1 2 3)'
# Fast path (all plain symbols) — must be byte-for-byte unchanged.
assert_eq 'fastpath'    "$("$BIN" -e '(let [x 1 y 2] (+ x y))')"                '3'

# --- cycle 2: associative {:keys/:syms/:or/:as/bare} ---
assert_eq 'map_keys'    "$("$BIN" -e '(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))')"           '3'
assert_eq 'map_or'      "$("$BIN" -e '(let [{:keys [a b] :or {b 10}} {:a 1}] (+ a b))')"     '11'
assert_eq 'map_as'      "$("$BIN" -e '(let [{:keys [a] :as m} {:a 1 :b 2}] [a (count m)])')" '[1 2]'
assert_eq 'map_bare'    "$("$BIN" -e '(let [{a :alpha b :beta} {:alpha 1 :beta 2}] (+ a b))')" '3'
assert_eq 'map_syms'    "$("$BIN" -e "(let [{:syms [q]} {'q 5}] q)")"                         '5'
assert_eq 'map_missing' "$("$BIN" -e '(let [{:keys [z]} {:a 1}] z)')"                         'nil'
assert_eq 'map_in_seq'  "$("$BIN" -e '(let [[{:keys [a]} c] [{:a 1} 2]] (+ a c))')"           '3'
assert_eq 'seq_in_map'  "$("$BIN" -e '(let [{[a b] :pair} {:pair [1 2]}] (+ a b))')"          '3'
# Note: `:strs` (string keys) is functionally blocked by the pre-existing
# map string-key lookup gap (D-151: `(get {"x" 5} "x")` → nil); its lowering
# is correct + forward-compatible, so it is intentionally not asserted here.

# --- cycle 3: fn / defn param destructuring (gensym param + body let) ---
assert_eq 'fn_seq_param'  "$("$BIN" -e '((fn [[a b]] (+ a b)) [1 2])')"                  '3'
assert_eq 'fn_map_param'  "$("$BIN" -e '((fn [{:keys [a b]}] (+ a b)) {:a 1 :b 2})')"    '3'
assert_eq 'fn_rest_pat'   "$("$BIN" -e '((fn [a & [b c]] (+ a b c)) 1 2 3)')"            '6'
assert_eq 'fn_plain_reg'  "$("$BIN" -e '((fn [a b] (+ a b)) 3 4)')"                      '7'
defn_map=$("$BIN" - <<'CLJ' 2>/dev/null
(defn f [{:keys [x]}] x)
(prn (f {:x 5}))
CLJ
)
assert_eq 'defn_map_param' "$(awk 'END{print}' <<< "$defn_map")" '5'
defn_multi=$("$BIN" - <<'CLJ' 2>/dev/null
(defn g ([[a]] a) ([[a b] c] (+ a b c)))
(prn [(g [9]) (g [1 2] 3)])
CLJ
)
assert_eq 'defn_multi_destructure' "$(awk 'END{print}' <<< "$defn_multi")" '[9 6]'

# --- cycle 4: loop macro (loop* rename) + loop destructuring ---
# Plain `(loop …)` was previously unresolved — `loop*` had to be written.
assert_eq 'loop_plain'  "$("$BIN" -e '(loop [x 0] (if (< x 3) (recur (inc x)) x))')"               '3'
assert_eq 'loop_seq'    "$("$BIN" -e '(loop [[a b] [1 2]] (if (< a 3) (recur [(inc a) b]) (+ a b)))')" '5'
assert_eq 'loop_rest'   "$("$BIN" -e '(loop [sum 0 [x & xs] [1 2 3]] (if x (recur (+ sum x) xs) sum))')" '6'
assert_eq 'loop_map'    "$("$BIN" -e '(loop [{:keys [n]} {:n 5}] (if (> n 0) (recur {:n (dec n)}) :done))')" ':done'
assert_eq 'loop_star'   "$("$BIN" -e '(loop* [x 0] (if (< x 2) (recur (inc x)) x))')"              '2'

# --- cycle 5: keyword-args destructuring (& {:keys [...]}) — a seq operand
# in a map-destructure is coerced to a map (Clojure (apply hash-map …)). ---
assert_eq 'kwargs_keys'      "$("$BIN" -e '((fn [& {:keys [x y]}] [x y]) :x 1 :y 2)')"        '[1 2]'
assert_eq 'kwargs_with_lead' "$("$BIN" -e '((fn [a & {:keys [x]}] [a x]) 1 :x 2)')"          '[1 2]'
assert_eq 'kwargs_or'        "$("$BIN" -e '((fn [& {:keys [x] :or {x 9}}] x))')"             '9'
assert_eq 'map_destr_of_seq' "$("$BIN" -e "(let [{:keys [x]} '(:x 1)] x)")"                  '1'

echo "OK — phase14_destructure smoke (31 cases) green"
