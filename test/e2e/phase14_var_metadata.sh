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
# meta map. Slice 1 (synthesize-on-read) now projects the MECHANICAL keys
# `:name`/`:ns`/`:macro`/`:dynamic`/`:private` from the Var's own fields onto
# `(meta #'x)` (matching clj's Var.setMeta forcing of :name/:ns). cljw still
# does NOT synthesize `:line`/`:file`, and `:ns` renders as a bare namespace
# (AD-013) not clj's `#object[...Namespace...]`, so full-map equality with clj
# still diverges — key extraction stays the test style. Builtin `:arglists`/
# `:doc` (a generated table) is a later slice; `:arglists` already lands for
# `defn`-defined vars (the defn macro attaches it).
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

# --- D-186: ^meta on a COLLECTION LITERAL in expression position (lowers to
# (with-meta lit meta); meta map values are evaluated, matching JVM) ---
assert_last 'coll_vec'     '(meta ^:foo [1 2 3])'              '{:foo true}'
assert_last 'coll_map'     '(:k (meta ^{:k 9} {:a 1}))'        '9'
assert_last 'coll_set'     '(:foo (meta ^:foo #{1 2}))'        'true'
assert_last 'coll_eval'    '(:a (meta ^{:a (+ 1 2)} [1]))'     '3'
assert_last 'coll_value'   '(conj ^:foo [1 2] 3)'              '[1 2 3]'

# --- #^meta — deprecated (pre-1.0) alias for ^meta (real old code: e.g.
# clojure.math.combinatorics's ns form uses #^{...}) ---
assert_last 'old_meta_coll'  '(:a (meta #^{:a 1} [1 2 3]))'           '1'
assert_last 'old_meta_def'   '(def #^{:doc "old"} om 5) (:doc (meta #'"'"'om))' '"old"'

# --- D-239: alter-meta! / reset-meta! on a Var (key extraction; cljw does
# not synthesize JVM :name/:ns/:line so full-map equality would diverge) ---
assert_last 'alter_var'    '(def av 1) (alter-meta! (var av) assoc :p 7) (:p (meta (var av)))' '7'
assert_last 'reset_var'    '(def rv 1) (reset-meta! (var rv) {:q 8}) (:q (meta (var rv)))'     '8'

# --- Slice 1: synthesize-on-read of mechanical keys (:name/:ns/:macro/
# :dynamic/:private) from the Var's own fields, merged UNDER user meta. ---
# :name is the bare symbol (no ns), present on every var incl. core/builtins.
assert_last 'synth_name_user'  '(def vn 1) (:name (meta #'"'"'vn))'              'vn'
assert_last 'synth_name_core'  '(:name (meta #'"'"'map))'                        'map'
# :ns is a first-class namespace value; ns-name yields its symbol.
assert_last 'synth_ns_core'    '(ns-name (:ns (meta #'"'"'map)))'                'clojure.core'
# :macro present (true) only for macros; absent (nil) otherwise.
assert_last 'synth_macro_t'    '(defmacro vmac [] nil) (:macro (meta #'"'"'vmac))' 'true'
assert_last 'synth_macro_nil'  '(:macro (meta #'"'"'map))'                       'nil'
# :dynamic present (true) only for ^:dynamic vars.
assert_last 'synth_dynamic'    '(def ^:dynamic *vd* 1) (:dynamic (meta #'"'"'*vd*))' 'true'
# defn keeps :arglists AND gains :name (synthesis merges, does not clobber).
assert_last 'synth_defn_keep'  '(defn vf [x y] x) [(:name (meta #'"'"'vf)) (:arglists (meta #'"'"'vf))]' '[vf ([x y])]'
# user meta survives synthesis (mechanical keys add, do not replace :doc etc).
assert_last 'synth_user_keep'  '(def ^{:doc "d"} vk 1) [(:name (meta #'"'"'vk)) (:doc (meta #'"'"'vk))]' '[vk "d"]'
# AD-021 pin: :ns renders opaquely as `#object[Namespace "…"]` (simple class
# name per AD-003, no identity hash per AD-002), NOT clj's
# `#object[clojure.lang.Namespace 0x… "clojure.core"]`. ns-name (synth_ns_core
# above) keeps behavioural equivalence (F-011); only the pr rendering diverges.
assert_last 'synth_ns_render'  '(pr-str (:ns (meta #'"'"'map)))'                '"#object[Namespace \"clojure.core\"]"'

echo "ALL phase14_var_metadata PASS"
