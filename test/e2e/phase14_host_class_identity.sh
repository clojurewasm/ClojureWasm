#!/usr/bin/env bash
# test/e2e/phase14_host_class_identity.sh
#
# ADR-0174 D1+D2 — host-class identity unification. One canonical
# descriptor per class; Java-surface-backed classes carry their JVM FQCN
# (natives / user types / exceptions keep simple names per AD-003); a
# class symbol resolves as a value through the same host_class_resolve
# rules the (Class/method) form uses (bare via java.lang auto-import,
# qualified, ns-imported); `=` between the resolved class value and
# `(class instance)` is identity on the one canonical descriptor —
# including for the formerly two-descriptor typed_instance family
# (Date / Instant / LocalDate / LocalTime / LocalDateTime / Duration).

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

run() { "$BIN" -e "$1" 2>/dev/null; }

# --- bare static-surface classes resolve as values (java.lang auto-import) ---
assert_eq 'bare_system'        "$(run 'System')"        'java.lang.System'
assert_eq 'bare_math'          "$(run 'Math')"          'java.lang.Math'
assert_eq 'bare_thread'        "$(run 'Thread')"        'java.lang.Thread'
assert_eq 'bare_stringbuilder' "$(run 'StringBuilder')" 'java.lang.StringBuilder'

# --- qualified forms resolve too ---
assert_eq 'fqcn_system'  "$(run 'java.lang.System')"   'java.lang.System'
assert_eq 'fqcn_date'    "$(run 'java.util.Date')"     'java.util.Date'
assert_eq 'fqcn_instant' "$(run 'java.time.Instant')"  'java.time.Instant'

# --- natives keep simple names (AD-003 scope unchanged) ---
assert_eq 'bare_long_simple'   "$(run 'Long')"   'Long'
assert_eq 'bare_string_simple' "$(run 'String')" 'String'
assert_eq 'exception_simple'   "$(run '(class (Exception. "x"))')" 'Exception'

# --- the cljw. prefix leak is dead ---
assert_eq 'class_stringbuilder' "$(run '(class (StringBuilder.))')" 'java.lang.StringBuilder'
assert_eq 'getname_stringbuilder' "$(run '(.getName (class (StringBuilder.)))')" '"java.lang.StringBuilder"'

# --- one canonical descriptor: = between class symbol and (class instance) ---
assert_eq 'date_identity'    "$(run '(= java.util.Date (class (java.util.Date. 0)))')" 'true'
assert_eq 'instant_identity' "$(run '(= java.time.Instant (class (java.time.Instant/now)))')" 'true'
assert_eq 'sb_identity'      "$(run '(= StringBuilder (class (StringBuilder.)))')" 'true'

# --- instance? over the merged descriptors ---
assert_eq 'instance_date'    "$(run '(instance? java.util.Date (java.util.Date. 0))')" 'true'
assert_eq 'instance_instant' "$(run '(instance? java.time.Instant (java.time.Instant/now))')" 'true'
assert_eq 'instance_date_negative' "$(run '(instance? java.util.Date 5)')" 'false'
assert_eq 'instance_system_negative' "$(run '(instance? java.lang.System 5)')" 'false'

# --- resolve returns the class value on a Var miss (clj parity) ---
assert_eq 'resolve_system' "$(run '(boolean (resolve (quote java.lang.System)))')" 'true'
assert_eq 'resolve_date'   "$(run '(boolean (resolve (quote java.util.Date)))')"   'true'

# --- typed_instance prints flip to FQCN (clj-faithful; AD-003 amendment) ---
assert_eq 'class_date_print'    "$(run '(class (java.util.Date. 0))')"  'java.util.Date'
assert_eq 'class_instant_print' "$(run '(class (java.time.Instant/now))')" 'java.time.Instant'
assert_eq 'class_duration_print' "$(run '(class (java.time.Duration/ofMillis 1))')" 'java.time.Duration'

# --- instance methods still dispatch on the merged descriptor ---
assert_eq 'date_gettime'   "$(run '(.getTime (java.util.Date. 42))')" '42'
assert_eq 'instant_millis' "$(run '(.toEpochMilli (java.time.Instant/ofEpochMilli 7))')" '7'

# --- statics still dispatch (registry keys flipped with the fqcns) ---
assert_eq 'system_getprop'  "$(run '(System/getProperty "os.name")' )" '"Mac OS X"'
assert_eq 'thread_static'   "$(run '(pos? (System/currentTimeMillis))')" 'true'

# --- Var shadowing still wins over class resolution ---
# (-e prints every top-level form's value; take the last line)
assert_eq 'def_shadows_class' "$(run '(def System 42) System' | tail -1)" '42'

# --- user code sees a clean class value through higher-order use ---
assert_eq 'group_by_class' "$(run '(contains? (group-by class [(java.util.Date. 0) (java.util.Date. 1)]) java.util.Date)')" 'true'

echo "ALL PASS"
