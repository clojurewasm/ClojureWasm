#!/usr/bin/env bash
# test/e2e/phase14_var_metadata.sh
#
# D-183 parts (b)+(c): the `^meta` reader macro + `def` honouring it.
# `^{m} target` / `^:kw target` / `^Sym target` attach metadata to the
# def target; `(meta (var x))` / `(meta #'x)` read it back. cljw symbols
# are metadata-less (ADR-0037), so the reader parks meta on the name
# Form's side-channel and `analyzeDef` lifts it into the Var's `.meta`.
#
# Assertions extract a KEY (`:doc`/`:private`/...) rather than the whole
# meta map: cljw intentionally does NOT synthesize JVM's `:name`/`:ns`/
# `:line`/`:file` keys yet (Reservation-as-bias avoidance per the survey),
# so full-map equality with clj would couple to that divergence. Key
# extraction is clj-grounded.
#
# `cljw -e` prints each top-level form's value, so each case asserts the
# LAST line.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }
assert_last() {
    local name="$1"; local expr="$2"; local want="$3"
    local got; got="$(last_line "$("$BIN" -e "$expr" 2>/dev/null)")"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- ^{map} on a def target → Var meta, read via (meta #'x) ---
assert_last 'meta_doc'     '(def ^{:doc "hi"} x 5) (:doc (meta #'"'"'x))'  '"hi"'
assert_last 'meta_map_a'   '(def ^{:a 1 :b 2} z 5) (:a (meta #'"'"'z))'    '1'
# --- ^:kw shorthand → {:kw true} ---
assert_last 'meta_private' '(def ^:private y 5) (:private (meta #'"'"'y))' 'true'
# --- ^Sym shorthand → {:tag Sym} (cljw keeps the bare symbol tag) ---
assert_last 'meta_tag'     '(def ^Foo s 1) (str (:tag (meta #'"'"'s)))'    '"Foo"'
# --- stacked metas merge, outer wins on dup keys ---
assert_last 'meta_stack'   '(def ^:a ^:b w 5) [(:a (meta #'"'"'w)) (:b (meta #'"'"'w))]' '[true true]'

echo "ALL phase14_var_metadata PASS"
