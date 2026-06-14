#!/usr/bin/env bash
# test/e2e/phase14_qualified_deftype.sh — D-428: resolve a USER deftype/defrecord
# by its FULLY-QUALIFIED `<ns>.<Type>` name (cross-namespace), as clj does for the
# JVM class a deftype generates. cljw keys user types by their SIMPLE name (AD-003,
# ADR-0059), so resolveClassValue falls back from the dotted form to the last
# segment — `(instance? a.b.Rec x)` / `(resolve 'a.b.Rec)` now work. This is the
# general gap instaparse's cfg.cljc:312 `(instance? instaparse.gll.Failure x)` hit.
# Oracle-confirmed == clj: true/false/true/true/true.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(ns a.b)
(defrecord Rec [x])
(deftype Typ [y])
(ns z (:require a.b))
(prn (instance? a.b.Rec (a.b/->Rec 1)))   ; true  — qualified defrecord
(prn (instance? a.b.Rec 5))               ; false
(prn (instance? a.b.Typ (a.b/->Typ 2)))   ; true  — qualified deftype
(prn (boolean (resolve 'a.b.Rec)))        ; true  — resolve a qualified type name
(prn (= a.b.Rec a.b.Rec))                 ; true  — identity of the class value
EOF
) || fail "qualified_deftype: non-zero exit ($got)"
assert_eq 'q_record_instance' "$(sed -n '1p' <<< "$got")" 'true'
assert_eq 'q_record_negative' "$(sed -n '2p' <<< "$got")" 'false'
assert_eq 'q_deftype_instance' "$(sed -n '3p' <<< "$got")" 'true'
assert_eq 'q_resolve'         "$(sed -n '4p' <<< "$got")" 'true'
assert_eq 'q_class_identity'  "$(sed -n '5p' <<< "$got")" 'true'

# host classes still resolve by their qualified name (no regression).
assert_eq 'host_qualified' "$("$BIN" - <<'EOF' 2>/dev/null
(prn [(instance? java.lang.String "x") (instance? java.lang.Long 5)])
EOF
)" '[true true]'

echo "OK — phase14_qualified_deftype (6 cases) green"
