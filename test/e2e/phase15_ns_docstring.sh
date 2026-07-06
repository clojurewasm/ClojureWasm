#!/usr/bin/env bash
# test/e2e/phase15_ns_docstring.sh — (ns name docstring? attr-map? refs*) (D-232).
# clj's ns form allows an optional docstring (string) and attr-map (map) after
# the name, before the references — virtually every real library opens this way.
# cljw treated the docstring/attr-map as a directive ("ns directive must be a
# list"). Now they are skipped. Surfaced by loading weavejester/medley
# (real-world library loading, F-010 step 3). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# ns with a docstring, then the ns is in effect (clojure.core referred)
assert_eq 'ns-docstring' \
  "$("$BIN" -e '(ns foo.bar "my docstring" (:refer-clojure)) [(name (ns-name *ns*)) (inc 41)]' 2>&1 | tail -1)" \
  '["foo.bar" 42]'

# ns with docstring + attr-map
assert_eq 'ns-docstring-attrmap' \
  "$("$BIN" -e '(ns baz "doc" {:author "x"} (:refer-clojure)) [(name (ns-name *ns*)) (inc 1)]' 2>&1 | tail -1)" \
  '["baz" 2]'

# ns with no docstring still works (regression)
assert_eq 'ns-no-docstring' \
  "$("$BIN" -e '(ns plain (:refer-clojure)) (name (ns-name *ns*))' 2>&1 | tail -1)" \
  '"plain"'

# The docstring LANDS as {:doc "…"} on the ns meta (D-239 sibling; was
# silently skipped). clj: (meta (find-ns 'x)) → {:doc "…"}.
assert_eq 'ns-doc-meta' \
  "$("$BIN" -e '(ns dm.doc "the doc") (in-ns (quote user)) (:doc (meta (find-ns (quote dm.doc))))' 2>&1 | tail -1)" \
  '"the doc"'

# alter-meta! / reset-meta! on a namespace (D-239 remainder) — mutate,
# read back, reset to nil.
assert_eq 'ns-alter-meta' \
  "$("$BIN" -e '(alter-meta! (find-ns (quote user)) assoc :k 1) [(:k (meta (find-ns (quote user)))) (do (reset-meta! (find-ns (quote user)) nil) (meta (find-ns (quote user))))]' 2>&1 | tail -1)" \
  '[1 nil]'

echo "OK — phase15_ns_docstring (5 cases) green"
