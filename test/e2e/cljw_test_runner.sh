#!/usr/bin/env bash
# test/e2e/cljw_test_runner.sh — `cljw.test`: discover clojure.test namespaces on
# the source path and run them, with no build step and no external runner. The
# compliance workflow (a suite of one .cljc namespace per core symbol) is the
# forcing case: `cljw -cp test -m cljw.test` must find every namespace, run it,
# report per-namespace and total counts, and exit non-zero when anything is red.
# Also pins `java.class.path`, the property the runner defaults its roots from.
# Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- a miniature suite: nested dirs, an underscore in a file name, a .cljc ----
mkdir -p "$WORK/test/demo/core_test"
cat > "$WORK/test/demo/core_test/inc.cljc" <<'EOF'
(ns demo.core-test.inc
  (:require [clojure.test :refer [deftest is]]))
(deftest test-inc
  (is (= 2 (inc 1)))
  (is (= 0 (inc -1))))
EOF
cat > "$WORK/test/demo/core_test/plus_one.clj" <<'EOF'
(ns demo.core-test.plus-one
  (:require [clojure.test :refer [deftest is]]))
(deftest test-plus (is (= 3 (+ 1 2))))
EOF

# --- java.class.path is the resolved source path -----------------------------
# (`-e` prints each form's value, so the assertion reads the first line only.)
assert_eq 'class-path' \
  "$("$BIN" -cp "$WORK/test" -e '(println (System/getProperty "java.class.path"))' | sed -n 1p)" \
  "$WORK/test"

# --- discovery + run: two namespaces, three assertions, exit 0 ---------------
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test 2>&1)"; code=$?
assert_eq 'green-exit' "$code" '0'
assert_has 'green-ns-inc' "$out" 'demo.core-test.inc'
assert_has 'green-ns-underscore' "$out" 'demo.core-test.plus-one'
assert_has 'green-totals' "$out" '2 namespaces, 2 tests, 3 assertions, 0 failures, 0 errors, 0 unloadable'

# --- an explicit root argument is honoured -----------------------------------
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test test 2>&1)"
assert_has 'explicit-root' "$out" '2 namespaces, 2 tests, 3 assertions, 0 failures, 0 errors'

# --- --include narrows the selection -----------------------------------------
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test --include 'plus' 2>&1)"
assert_has 'include-filter' "$out" '1 namespaces, 1 tests, 1 assertions, 0 failures, 0 errors'

# --- --exclude drops namespaces ----------------------------------------------
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test --exclude 'plus' 2>&1)"
assert_has 'exclude-filter' "$out" '1 namespaces, 1 tests, 2 assertions, 0 failures, 0 errors'

# --- a red namespace fails the run -------------------------------------------
cat > "$WORK/test/demo/core_test/broken.clj" <<'EOF'
(ns demo.core-test.broken
  (:require [clojure.test :refer [deftest is]]))
(deftest test-broken (is (= 1 2)))
EOF
set +e
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test 2>&1)"; code=$?
set -e
assert_eq 'red-exit' "$code" '1'
assert_has 'red-totals' "$out" '1 failures'

# --- a namespace that throws while loading is reported, and the rest still run
cat > "$WORK/test/demo/core_test/unloadable.clj" <<'EOF'
(ns demo.core-test.unloadable)
(throw (ex-info "load blew up" {}))
EOF
rm "$WORK/test/demo/core_test/broken.clj"
set +e
out="$(cd "$WORK" && "$BIN" -cp test -m cljw.test 2>&1)"; code=$?
set -e
assert_eq 'load-error-exit' "$code" '1'
assert_has 'load-error-named' "$out" 'demo.core-test.unloadable'
# A namespace that never loaded ran no assertions: it is counted as unloadable,
# and the assertion count stays the truth about what actually ran.
assert_has 'load-error-counted' "$out" '1 unloadable'
assert_has 'load-error-others-ran' "$out" '3 assertions'

# --- clojure.test/successful? is the clj-compat verdict the runner uses ------
verdict() { "$BIN" -e "(require (quote clojure.test)) (println (clojure.test/successful? $1))" | tail -2 | sed -n 1p; }
assert_eq 'successful-true'  "$(verdict '{:test 1 :pass 2 :fail 0 :error 0}')" 'true'
assert_eq 'successful-false' "$(verdict '{:test 1 :pass 2 :fail 1 :error 0}')" 'false'

echo "OK cljw_test_runner"
