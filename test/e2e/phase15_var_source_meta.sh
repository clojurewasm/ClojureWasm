#!/usr/bin/env bash
# test/e2e/phase15_var_source_meta.sh
#
# D-563(b) — Vars carry :line/:column/:file source meta (clj compiler
# parity), user ^meta wins on collision, and DEF META RIDES THE WIRE:
# the op_def_meta opcode builds the meta map at runtime and the VM sets
# Var.meta, so an AOT artifact (`cljw build`) keeps :doc/:line — the
# pre-existing user-AOT :doc loss (docstrings vanished in built apps
# while the lazy-source core kept them) is fixed by the same channel.
# clojure.test failure lines regain their ` (file:line)` suffix
# (AD-041 dissolved).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
assert_contains() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name"
}

run() { "$BIN" - <<EOF 2>&1 || true
$1
EOF
}

# --- :line/:column/:file land on every def'd Var ---
assert_eq 'line_col' "$(run '(def a 1)
(defn f [x] x)
(println [(:line (meta (var a))) (pos? (:column (meta (var a)))) (:line (meta (var f)))])')" '[1 true 2]'
assert_eq 'file_is_label' "$(run '(def a 1)
(println (string? (:file (meta (var a)))))')" 'true'

# --- user ^meta + docstring still there; user :line wins on collision ---
assert_eq 'doc_and_user_meta' "$(run '(defn g "gdoc" {:author "me"} [x] x)
(println [(:doc (meta (var g))) (:author (meta (var g)))])')" '[gdoc me]'
# clj oracle: the COMPILER's :line overrides a user ^{:line} (other keys merge)
assert_eq 'compiler_line_wins' "$(run '(def ^{:line 999 :author "me"} h 1)
(println [(:line (meta (var h))) (:author (meta (var h)))])')" '[1 me]'

# --- fixture file: :file is the real path, :line the real line ---
fixdir=$(mktemp -d)
trap 'rm -rf "$fixdir"' EXIT
cat > "$fixdir/src_meta_fix.clj" <<'EOF'
(ns src-meta-fix)

(defn fixture-fn [x] x)
(println [(:line (meta (var fixture-fn))) (clojure.string/includes? (str (:file (meta (var fixture-fn)))) "src_meta_fix")])
EOF
got=$("$BIN" "$fixdir/src_meta_fix.clj" 2>&1 || true)
assert_eq 'fixture_line_file' "$got" '[3 true]'

# --- AOT: def meta rides the wire (the user-artifact :doc loss is fixed) ---
cat > "$fixdir/main.clj" <<'EOF'
(defn built-fn "built doc" [x] (inc x))
(println [(:doc (meta (var built-fn))) (pos? (or (:line (meta (var built-fn))) 0))])
EOF
(cd "$fixdir" && "$BIN" build main.clj -o app >/dev/null 2>&1)
got=$("$fixdir/app" 2>&1 | tail -1)
assert_eq 'aot_meta_survives' "$got" '[built doc true]'

# --- clojure.test failure lines regain the (file:line) suffix ---
got=$(run '(require (quote [clojure.test :refer [deftest is run-tests]]))
(deftest failing-t (is (= 1 2)))
(run-tests)')
assert_contains 'test_file_line_suffix' "$got" 'failing-t) ('

echo "ALL PASS"
