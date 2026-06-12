#!/usr/bin/env bash
# test/e2e/phase16_java_io_file.sh
#
# ADR-0126 Cycle 1 — java.io.File host type (host_instance shape).
# Query / path / mutation methods over the file_io neutral impl, FS-jail-aware.
# class / instance? / print (opaque) per the Random precedent (AD-020).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

run() { "$BIN" -e "$1" 2>/dev/null; }

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

TMP="/tmp/cljw_jio_file_test"
rm -rf "$TMP"; mkdir -p "$TMP/sub"
echo "hello" > "$TMP/a.txt"

# --- class / instance? / print (opaque, AD-020) ---
assert_eq 'class'        "$(run '(class (java.io.File. "/tmp"))')"                 'java.io.File'
assert_eq 'instance_pos' "$(run '(instance? java.io.File (java.io.File. "/tmp"))')" 'true'
assert_eq 'instance_neg' "$(run '(instance? java.io.File 5)')"                     'false'

# --- pure path methods (no FS touch); cljw -e prints string results pr-quoted ---
assert_eq 'getName'      "$(run '(.getName (java.io.File. "/a/b/c.txt"))')"        '"c.txt"'
assert_eq 'getPath'      "$(run '(.getPath (java.io.File. "/a/b/c.txt"))')"        '"/a/b/c.txt"'
assert_eq 'getParent'    "$(run '(.getParent (java.io.File. "/a/b/c.txt"))')"      '"/a/b"'
assert_eq 'getParent_nil' "$(run '(.getParent (java.io.File. "x"))')"             'nil'
assert_eq 'isAbsolute_t' "$(run '(.isAbsolute (java.io.File. "/a"))')"             'true'
assert_eq 'isAbsolute_f' "$(run '(.isAbsolute (java.io.File. "a/b"))')"            'false'
assert_eq 'toString'     "$(run '(str (java.io.File. "/a/b"))')"                   '"/a/b"'
assert_eq 'getParentFile' "$(run '(.getName (.getParentFile (java.io.File. "/a/b/c")))')" '"b"'

# --- getAbsolutePath / getCanonicalPath (D-357, via std.process.currentPathAlloc) ---
assert_eq 'absPath_abs'  "$(run '(.getAbsolutePath (java.io.File. "/a/b/c.txt"))')" '"/a/b/c.txt"'
assert_eq 'absPath_rel'  "$(run '(.isAbsolute (java.io.File. (.getAbsolutePath (java.io.File. "rel/x"))))')" 'true'
assert_eq 'canon_dotdot' "$(run '(.getCanonicalPath (java.io.File. "/a/./b/../c"))')" '"/a/c"'

# --- 2-arg ctor (parent + child) ---
assert_eq 'ctor2'        "$(run '(.getPath (java.io.File. "/a/b" "c.txt"))')"      '"/a/b/c.txt"'
assert_eq 'ctor2_file'   "$(run '(.getPath (java.io.File. (java.io.File. "/a") "b"))')" '"/a/b"'

# --- FS-touch query methods ---
assert_eq 'exists_t'     "$(run "(.exists (java.io.File. \"$TMP/a.txt\"))")"       'true'
assert_eq 'exists_f'     "$(run "(.exists (java.io.File. \"$TMP/nope\"))")"        'false'
assert_eq 'isFile_t'     "$(run "(.isFile (java.io.File. \"$TMP/a.txt\"))")"       'true'
assert_eq 'isFile_dir'   "$(run "(.isFile (java.io.File. \"$TMP/sub\"))")"         'false'
assert_eq 'isDir_t'      "$(run "(.isDirectory (java.io.File. \"$TMP/sub\"))")"    'true'
assert_eq 'isDir_file'   "$(run "(.isDirectory (java.io.File. \"$TMP/a.txt\"))")"  'false'
assert_eq 'length'       "$(run "(.length (java.io.File. \"$TMP/a.txt\"))")"       '6'
assert_eq 'canRead'      "$(run "(.canRead (java.io.File. \"$TMP/a.txt\"))")"      'true'

# --- mutation methods ---
assert_eq 'mkdir'        "$(run "(.mkdir (java.io.File. \"$TMP/d1\"))")"           'true'
assert_eq 'mkdirs'       "$(run "(.mkdirs (java.io.File. \"$TMP/d2/d3/d4\"))")"    'true'
assert_eq 'delete'       "$(run "(.delete (java.io.File. \"$TMP/d1\"))")"          'true'
assert_eq 'delete_gone'  "$(run "(.delete (java.io.File. \"$TMP/never\"))")"       'false'

# --- listing (sorted for determinism) ---
assert_eq 'list'         "$(run "(sort (seq (.list (java.io.File. \"$TMP\"))))")"  '("a.txt" "d2" "sub")'

rm -rf "$TMP"
echo "ALL PASS phase16_java_io_file"
