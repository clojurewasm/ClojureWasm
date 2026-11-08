#!/usr/bin/env bash
# test/e2e/phase14_file_var.sh — `clojure.core/*file*` (the 2026-08-04 audit's
# one genuinely untracked gap: absent from cljw AND absent from .dev/debt.yaml).
#
# JVM Clojure semantics, oracle-checked against clj 2026-08-04:
#   clj -M -e '…'      => "NO_SOURCE_PATH"
#   clj -M script.clj  => the given path
#   during (require 'x) => the classpath-relative resource name
# The first two are asserted here; the third needs the load path to bind it and
# is not wired yet, so it is deliberately NOT claimed.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# A real file reports its own path — the whole point of the var.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '(println (pr-str *file*))\n' > "$TMP/probe.clj"
assert_eq 'file-reports-path' "$("$BIN" "$TMP/probe.clj" 2>&1 | tail -1)" "\"$TMP/probe.clj\""

# Non-file sources report clj's exact sentinel. The guard is a positive test
# (a real path never starts with '<'), not a denylist — a denylist missed the
# `<-e>` label and reported it as the file name.
assert_eq 'e-form-sentinel'  "$("$BIN" -e '(println (pr-str *file*))' 2>&1 | sed -n 1p)" '"NO_SOURCE_PATH"'
assert_eq 'stdin-sentinel'   "$(printf '(println (pr-str *file*))\n' | "$BIN" - 2>&1 | sed -n 1p)" '"NO_SOURCE_PATH"'

# It is ^:dynamic, so a caller can rebind it the way tooling does.
got="$("$BIN" -e '(binding [*file* "x.clj"] (println (pr-str *file*)))' 2>&1 | sed -n 1p)"
assert_eq 'rebindable' "$got" '"x.clj"'

echo "OK — phase14_file_var (4 cases) green"
