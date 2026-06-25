#!/usr/bin/env bash
# test/e2e/phase16_clojure_java_io.sh
#
# ADR-0126 Cycle 2 — clojure.java.io file family (Coercions + file /
# as-relative-path / delete-file / make-parents) over the java.io.File host
# type. cljw-style cond dispatch (no protocol-to-String); ex-info throws.
#
# clojure.java.io is eager-loaded (FILES), so the fully-qualified names resolve
# without a require. The `:as` alias path (the user-facing form) is covered by
# the fixture-file smoke at the end — an alias established by a runtime require
# is only visible to SUBSEQUENT top-level forms, so it cannot be exercised
# inside a single `-e (do (require …) …)` (the whole form analyses before eval).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

run() { "$BIN" -e "$1" 2>&1 | tail -n 1; }

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

TMP="/tmp/cljw_cji_test"
rm -rf "$TMP"; mkdir -p "$TMP"
echo "x" > "$TMP/del.txt"

# --- file / as-file ---
assert_eq 'file_1'      "$(run '(.getPath (clojure.java.io/file "/a/b"))')"             '"/a/b"'
assert_eq 'file_2'      "$(run '(.getPath (clojure.java.io/file "/a" "b/c.txt"))')"     '"/a/b/c.txt"'
assert_eq 'file_3'      "$(run '(.getPath (clojure.java.io/file "/a" "b" "c"))')"       '"/a/b/c"'
assert_eq 'file_class'  "$(run '(instance? java.io.File (clojure.java.io/file "/a"))')" 'true'
assert_eq 'as_file_str' "$(run '(.getPath (clojure.java.io/as-file "/x/y"))')"          '"/x/y"'
assert_eq 'as_file_nil' "$(run '(clojure.java.io/as-file nil)')"                        'nil'
assert_eq 'as_file_idem' "$(run '(.getPath (clojure.java.io/as-file (clojure.java.io/file "/z")))')" '"/z"'

# --- as-relative-path ---
assert_eq 'rel_ok'      "$(run '(clojure.java.io/as-relative-path "a/b")')"             '"a/b"'
assert_eq 'rel_abs_throws' "$(run '(try (clojure.java.io/as-relative-path "/abs") (catch Throwable e :threw))')" ':threw'

# --- delete-file ---
assert_eq 'delete_ok'   "$(run "(clojure.java.io/delete-file \"$TMP/del.txt\")")"       'true'
assert_eq 'delete_silently' "$(run "(clojure.java.io/delete-file \"$TMP/gone\" :skipped)")" ':skipped'
assert_eq 'delete_throws' "$(run "(try (clojure.java.io/delete-file \"$TMP/gone\") (catch Throwable e :threw))")" ':threw'

# --- make-parents (creates parent dirs of the target file) ---
assert_eq 'make_parents' "$(run "(clojure.java.io/make-parents (clojure.java.io/file \"$TMP\" \"d1/d2/leaf.txt\"))")" 'true'
assert_eq 'parents_made' "$(run "(.isDirectory (clojure.java.io/file \"$TMP/d1/d2\"))")" 'true'

# --- as-url → java.net.URI (D-359); resource stays nil (no classpath) ---
assert_eq 'as_url_nil'    "$(run '(clojure.java.io/as-url nil)')" 'nil'
assert_eq 'as_url_str'    "$(run '(str (clojure.java.io/as-url "http://x/y"))')" '"http://x/y"'
assert_eq 'as_url_file'   "$(run '(str (clojure.java.io/as-url (clojure.java.io/file "/a/b")))')" '"file:///a/b"'
assert_eq 'as_url_uri'    "$(run '(instance? java.net.URI (clojure.java.io/as-url "http://x"))')" 'true'
assert_eq 'as_url_bad'    "$(run '(try (clojure.java.io/as-url 42) (catch Throwable e :threw))')" ':threw'
# reader over a file: URI reads the file (http(s) URIs fetch via cljw.http.client).
printf 'uri-body' > "$TMP/uri.txt"
assert_eq 'reader_file_uri' "$(run "(rt/__stream-slurp (clojure.java.io/reader (java.net.URI. \"file://$TMP/uri.txt\")))")" '"uri-body"'
assert_eq 'resource_nil'  "$(run '(clojure.java.io/resource "config.edn")')" 'nil'
assert_eq 'resource_gd'   "$(run '(if-let [r (clojure.java.io/resource "x")] :found :none)')" ':none'

# --- :as alias path (the user-facing form), via a fixture file (sequential eval) ---
FIX="$TMP/alias_smoke.clj"
cat > "$FIX" <<EOF
(require '[clojure.java.io :as io])
(println (.getPath (io/file "/a" "b")))
EOF
assert_eq 'alias_via_require' "$("$BIN" "$FIX" 2>&1 | tail -n 1)" '/a/b'

# --- spit `& options`: :append (truthy → append; false → truncate) + :encoding
# (UTF-8 no-op). clj signature (spit f content & options). Sequential top-level
# forms via a fixture (a single -e analyses the whole form before eval).
APP="$TMP/append_smoke.clj"
cat > "$APP" <<EOF
(spit "$TMP/ap.txt" "1")
(spit "$TMP/ap.txt" "2" :append true)
(spit "$TMP/ap.txt" "3" :append true)
(println (slurp "$TMP/ap.txt"))            ; 123 — appended
(spit "$TMP/ap2.txt" "X" :append true)     ; append to a MISSING file == create
(println (slurp "$TMP/ap2.txt"))           ; X
(spit "$TMP/ap.txt" "reset" :append false) ; :append false truncates
(println (slurp "$TMP/ap.txt"))            ; reset
(spit "$TMP/ap.txt" "enc" :encoding "UTF-8") ; :encoding accepted (UTF-8)
(println (slurp "$TMP/ap.txt"))            ; enc
(spit "$TMP/cc.txt" 42)                     ; content (str)-coerced: non-string
(println (slurp "$TMP/cc.txt"))            ; 42
(spit "$TMP/cc.txt" {:a 1})
(println (slurp "$TMP/cc.txt"))            ; {:a 1}
EOF
assert_eq 'spit_append_options' "$("$BIN" "$APP" 2>&1)" $'123\nX\nreset\nenc\n42\n{:a 1}'

# --- D-471: slurp/spit accept a java.io.File arg (clojure.java.io/Coercions).
# cljw extracts the File's stored path (state[0]); clj routes via Coercions/IOFactory.
FARG="$TMP/farg_smoke.clj"
cat > "$FARG" <<EOF
(spit (clojure.java.io/file "$TMP/farg.txt") "filebody")   ; File arg to spit
(println (slurp (clojure.java.io/file "$TMP/farg.txt")))   ; File arg to slurp
(spit (clojure.java.io/file "$TMP" "sub.txt") "nested")    ; multi-segment File
(println (slurp (clojure.java.io/file "$TMP/sub.txt")))    ; nested
EOF
assert_eq 'slurp_spit_file_arg' "$("$BIN" "$FARG" 2>&1)" $'filebody\nnested'

rm -rf "$TMP"
echo "ALL PASS phase16_clojure_java_io"
