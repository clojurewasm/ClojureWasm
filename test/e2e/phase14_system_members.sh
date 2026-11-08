#!/usr/bin/env bash
# test/e2e/phase14_system_members.sh
#
# ADR-0174 D5 — java.lang.System close-out (the member fill beyond the
# original 8): getProperties (cljw persistent map over the OS-truthful
# static set + the setProperty overlay — clj returns java.util.Properties,
# a Map; the map-shaped reads below are oracle-identical), 0-arg getenv
# (full env map), clearProperty (overlay remove, returns previous),
# identityHashCode (cljw identity hash — AD: not JVM object headers),
# gc (a hint, like the JVM — triggers a safe collect or no-ops).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

run() { "$BIN" - <<EOF 2>&1
$1
EOF
}

# --- getProperties: map-shaped, carries the static set + overlay ---
assert_eq 'getprops_osname' "$(run '(println (= (get (System/getProperties) "os.name") (System/getProperty "os.name")))')" 'true'
assert_eq 'getprops_static' "$(run '(println (get (System/getProperties) "file.separator"))')" '/'
assert_eq 'getprops_overlay' "$(run '(System/setProperty "cljw.test.k" "v1")
(println (get (System/getProperties) "cljw.test.k"))')" 'v1'
assert_eq 'getprops_into_map' "$(run '(println (map? (into {} (System/getProperties))))')" 'true'

# --- clearProperty: returns previous, removes the overlay entry ---
assert_eq 'clear_roundtrip' "$(run '(System/setProperty "cljw.test.k" "v1")
(println [(System/clearProperty "cljw.test.k") (System/getProperty "cljw.test.k")])')" '[v1 nil]'
assert_eq 'clear_unset' "$(run '(println (System/clearProperty "cljw.never.set"))')" 'nil'

# --- 0-arg getenv: the full environment as a map ---
assert_eq 'getenv_map' "$(run '(println (map? (System/getenv)))')" 'true'
assert_eq 'getenv_consistent' "$(run '(println (= (get (System/getenv) "HOME") (System/getenv "HOME")))')" 'true'

# --- identityHashCode: an int, stable per identity within a run ---
assert_eq 'idhash_int' "$(run '(println (int? (System/identityHashCode (Object.))))')" 'true'
assert_eq 'idhash_stable' "$(run '(def x (Object.))
(println (= (System/identityHashCode x) (System/identityHashCode x)))')" 'true'
assert_eq 'idhash_nil_zero' "$(run '(println (System/identityHashCode nil))')" '0'

# --- gc: a hint; returns nil and the program continues correctly ---
assert_eq 'gc_hint' "$(run '(def keep-me (vec (range 1000)))
(println [(System/gc) (count keep-me) (peek keep-me)])')" '[nil 1000 999]'

# --- System/out + System/err + System/in (ADR-0174 D5b) ---
assert_eq 'out_println' "$(run '(.println System/out "via-out")')" 'via-out'
assert_eq 'out_print_flush' "$(run '(.print System/out "a")
(.print System/out "b")
(.flush System/out)')" 'ab'
assert_eq 'out_class' "$(run '(println (str (class System/out)))')" 'java.io.PrintStream'
assert_eq 'in_class'  "$(run '(println (str (class System/in)))')" 'java.io.BufferedInputStream'
assert_eq 'out_instance_outputstream' "$(run '(println (instance? java.io.OutputStream System/out))')" 'true'
assert_eq 'out_singleton' "$(run '(println (identical? System/out System/out))')" 'true'
# println of a non-string prints its str form (JVM String.valueOf ≈ str)
assert_eq 'out_println_value' "$(run '(.println System/out 42)')" '42'
# interleaving with the cljw print path stays ordered (per-call autoflush)
assert_eq 'out_interleave' "$(run '(println "one")
(.println System/out "two")
(println "three")')" $'one\ntwo\nthree'
# err writes ONLY to stderr
got_out=$("$BIN" -e '(.println System/err "e1")' 2>/dev/null)
got_err=$("$BIN" -e '(.println System/err "e2")' 2>&1 >/dev/null)
[[ "$got_out" == "nil" && "$got_err" == "e2" ]] || fail "err_channel: out='$got_out' err='$got_err'"
echo "PASS err_channel"
# System/in reads piped bytes ("h"=104, "i"=105), then EOF -1
# `sed -n 1p`, NOT `head -1`: head exits after line 1 and closes the pipe, so
# cljw's later write (the -e nil echo / final flush) can hit EPIPE on a loaded
# host → cljw exits non-zero → under `set -eo pipefail` the assignment dies
# WITHOUT printing FAIL (the 2026-07-29 CI-runner flake). sed reads to EOF.
got=$(echo "hi" | "$BIN" -e '(prn [(.read System/in) (.read System/in) (.read System/in) (.read System/in) (.read System/in)])' 2>&1 | sed -n '1p')
[[ "$got" == '[104 105 10 -1 -1]' ]] || fail "in_read: got '$got'"
echo "PASS in_read"

echo "ALL PASS"
