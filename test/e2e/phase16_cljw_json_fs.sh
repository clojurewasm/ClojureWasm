#!/usr/bin/env bash
# test/e2e/phase16_cljw_json_fs.sh
#
# ADR-0126 Cycle 7 — cljw.json + cljw.fs handy wrappers (require-able cljw.*).
# cljw.json: encode/decode(keywordized)/decode-strict over clojure.data.json.
# cljw.fs: babashka.fs-style predicates/ops over java.io.File. Both eager-loaded
# so fully-qualified names resolve without a require.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

run() { "$BIN" -e "(do (require (quote [cljw.json]) (quote [cljw.fs])) $1)" 2>&1 | tail -n 1; }
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

TMP="/tmp/cljw_json_fs_test"; rm -rf "$TMP"; mkdir -p "$TMP/sub"
printf '0123456789' > "$TMP/ten.txt"

# --- cljw.json ---
# encode returns a String; cljw -e prints it pr-quoted (inner quotes escaped).
assert_eq 'json_encode'  "$(run '(cljw.json/encode {:a 1 :b [2 3]})')" '"{\"a\":1,\"b\":[2,3]}"'
assert_eq 'json_decode_kw' "$(run '(cljw.json/decode "{\"name\":\"x\",\"nested\":{\"k\":1}}")')" '{:name "x", :nested {:k 1}}'
assert_eq 'json_decode_get' "$(run '(:code (cljw.json/decode "{\"code\":\"(+ 1 2)\"}"))')" '"(+ 1 2)"'
assert_eq 'json_decode_strict' "$(run '(get (cljw.json/decode-strict "{\"a\":1}") "a")')" '1'
assert_eq 'json_roundtrip' "$(run '(cljw.json/decode (cljw.json/encode {:x [1 2 3]}))')" '{:x [1 2 3]}'
# write-str / read-str delegate at call time (not a def-alias): with-redefs of
# the data.json var reaches them, options pass through, and the vars document.
assert_eq 'json_write_str_redefs' "$(run '(with-redefs [clojure.data.json/write-str (fn [& _] "X")] (cljw.json/write-str {:a 1}))')" '"X"'
assert_eq 'json_read_str_opts' "$(run '(cljw.json/read-str "{\"a\":1}" :key-fn keyword)')" '{:a 1}'
assert_eq 'json_write_str_arglists' "$(run '(:arglists (meta (var cljw.json/write-str)))')" '([x & options])'
assert_eq 'json_read_str_doc' "$(run '(string? (:doc (meta (var cljw.json/read-str))))')" 'true'

# --- cljw.fs ---
assert_eq 'fs_exists'    "$(run "(cljw.fs/exists? \"$TMP/ten.txt\")")" 'true'
assert_eq 'fs_exists_no' "$(run "(cljw.fs/exists? \"$TMP/nope\")")" 'false'
assert_eq 'fs_regular'   "$(run "(cljw.fs/regular-file? \"$TMP/ten.txt\")")" 'true'
assert_eq 'fs_dir'       "$(run "(cljw.fs/directory? \"$TMP/sub\")")" 'true'
assert_eq 'fs_name'      "$(run "(cljw.fs/file-name \"$TMP/ten.txt\")")" '"ten.txt"'
assert_eq 'fs_size'      "$(run "(cljw.fs/size \"$TMP/ten.txt\")")" '10'
assert_eq 'fs_path'      "$(run "(cljw.fs/path \"$TMP/ten.txt\")")" "\"$TMP/ten.txt\""
assert_eq 'fs_create_dirs' "$(run "(cljw.fs/create-dirs \"$TMP/a/b/c\")")" 'true'
assert_eq 'fs_made'      "$(run "(cljw.fs/directory? \"$TMP/a/b/c\")")" 'true'

# --- :as alias path (user-facing), via a fixture file ---
cat > "$TMP/alias.clj" <<EOF
(require '[cljw.json :as json] '[cljw.fs :as fs])
(println (json/encode {:ok true}))
(println (fs/exists? "$TMP/ten.txt"))
EOF
assert_eq 'alias_smoke' "$("$BIN" "$TMP/alias.clj" 2>&1 | tail -n 1)" 'true'

rm -rf "$TMP"
echo "ALL PASS phase16_cljw_json_fs"
