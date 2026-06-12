#!/usr/bin/env bash
# test/e2e/phase14_defn_meta.sh
#
# D-183 part (d) / D-091 discharge: `defn` lowers its docstring + attr-map
# + synthesized `:arglists` into the Var metadata (previously parsed and
# DROPPED). Rides the part-(b)/(c) path: `expandDefn` parks the meta map on
# the name Form's `.meta` side-channel, `analyzeDef` lifts it into
# `Var.meta`, `(meta #'f)` reads it back. Reader meta on the name
# (`^:private`) is preserved + merged.
#
# `cljw -e` prints each top-level form's value, so each case asserts the
# LAST line. clj-grounded (key extraction).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }
assert_last() {
    local name="$1"; local expr="$2"; local want="$3"
    local got; got="$(last_line "$("$BIN" -e "$expr" 2>/dev/null)")"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- docstring → :doc ---
assert_last 'defn_doc'      '(defn f "docs" [a b] a) (:doc (meta #'"'"'f))'          '"docs"'
# --- attr-map merged ---
assert_last 'defn_attr'     '(defn g "d" {:custom 1} [a] a) (:custom (meta #'"'"'g))' '1'
# --- :arglists synthesized (always), single + multi-arity ---
assert_last 'defn_arglists' '(defn h "d" [a b] a) (:arglists (meta #'"'"'h))'   '([a b])'
assert_last 'defn_arglists_multi' '(defn m ([a] a) ([a b] b)) (:arglists (meta #'"'"'m))' '([a] [a b])'
assert_last 'defn_plain_arglists' '(defn plain [a] a) (:arglists (meta #'"'"'plain))'      '([a])'
# --- reader meta (^:private) preserved + merged with docstring ---
assert_last 'defn_private_doc' '(defn ^:private p "d" [a] a) [(:private (meta #'"'"'p)) (:doc (meta #'"'"'p))]' '[true "d"]'

# --- D-187: defmacro accepts + lowers docstring / attr-map / :arglists
# (was a hard "parameter list must be a vector" error). ---
assert_last 'defmacro_works'   '(defmacro mm "doc" [x] (list (quote inc) x)) (mm 5)'           '6'
assert_last 'defmacro_doc'     '(defmacro mm "the doc" [x] x) (:doc (meta #'"'"'mm))'           '"the doc"'
assert_last 'defmacro_attr'    '(defmacro mm "d" {:custom 9} [x] x) (:custom (meta #'"'"'mm))'  '9'
assert_last 'defmacro_arglists' '(defmacro mm [x] x) (:arglists (meta #'"'"'mm))'               '([x])'

echo "ALL phase14_defn_meta PASS"
