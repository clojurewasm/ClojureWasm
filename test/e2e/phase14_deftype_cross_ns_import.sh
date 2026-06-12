#!/usr/bin/env bash
# test/e2e/phase14_deftype_cross_ns_import.sh — cross-ns `(:import [ns Type])`
# of a USER deftype (D-391). A deftype defined in one ns and imported into
# another by its bare name must resolve there as a class VALUE — so
# `(instance? Type x)` (instance? is a fn whose class arg evaluates),
# `(extend-protocol P Type …)`, and a bare `Type` reference all work.
# Blocked hiccup.core (hiccup.util `(deftype RawString …)` imported by
# hiccup.compiler then used bare at compiler.clj:200). Mirrors clj: every
# deftype is a class importable via `:import`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

CP="$(mktemp -d)"; trap 'rm -rf "$CP"' EXIT
mkdir -p "$CP/ml"
cat > "$CP/ml/util.clj" <<'CLJ'
(ns ml.util)
(deftype RawString [s])
(defprotocol Render (render [this]))
CLJ
cat > "$CP/ml/cons.clj" <<'CLJ'
(ns ml.cons
  (:require [ml.util :as util])
  (:import [ml.util RawString]))
;; bare imported deftype resolves as a class VALUE (instance? is a fn)
(defn check-instance [] (instance? RawString (RawString. "x")))
;; bare imported deftype used as an extend-protocol type marker
(extend-protocol ml.util/Render
  RawString
  (render [this] "raw"))
(defn check-extend [] (ml.util/render (RawString. "y")))
CLJ

assert_eq 'cross-ns-instance?' \
  "$("$BIN" -cp "$CP" -e '(require (quote ml.cons)) (ml.cons/check-instance)' 2>&1 | tail -1)" 'true'
assert_eq 'cross-ns-extend-protocol' \
  "$("$BIN" -cp "$CP" -e '(require (quote ml.cons)) (ml.cons/check-extend)' 2>&1 | tail -1)" '"raw"'

echo "OK — phase14_deftype_cross_ns_import (2 cases) green"
