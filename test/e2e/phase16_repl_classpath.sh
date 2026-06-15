#!/usr/bin/env bash
# test/e2e/phase16_repl_classpath.sh — the interactive REPL is classpath-aware:
# `(require 'my.lib)` at a REPL prompt resolves `my/lib.clj` off the classpath,
# for all THREE REPL entry paths (D-322): `cljw -cp DIR` (flags-but-no-source),
# `cljw repl` + $CLJW_PATH (subcommand), and bare `cljw` + $CLJW_PATH (no-args).
# Before this fix none of the three threaded load_paths into repl.run, so a REPL
# require only saw the embedded resolver — no filesystem classpath.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

CP=$(mktemp -d)
trap 'rm -rf "$CP"' EXIT
mkdir -p "$CP/my"
cat > "$CP/my/lib.clj" <<'CLJ'
(ns my.lib)
(defn greet [] "hello-from-classpath")
CLJ

# (quote my.lib) avoids a literal ' inside the single-quoted shell string.
PROG='(require (quote my.lib)) (println (my.lib/greet))'

# (c) flags-but-no-source: `cljw -cp DIR` must START a classpath-aware REPL
# (was: print the bare "ClojureWasm" banner and exit).
got=$(printf '%s\n' "$PROG" | "$BIN" -cp "$CP" 2>/dev/null)
[[ "$got" == *hello-from-classpath* ]] || fail "cp_flag_repl: got '$got'"
echo "PASS cp_flag_repl"

# (a) `cljw repl` subcommand honours $CLJW_PATH.
got=$(printf '%s\n' "$PROG" | CLJW_PATH="$CP" "$BIN" repl 2>/dev/null)
[[ "$got" == *hello-from-classpath* ]] || fail "repl_subcmd_classpath: got '$got'"
echo "PASS repl_subcmd_classpath"

# (b) no-args bare `cljw` honours $CLJW_PATH.
got=$(printf '%s\n' "$PROG" | CLJW_PATH="$CP" "$BIN" 2>/dev/null)
[[ "$got" == *hello-from-classpath* ]] || fail "noargs_classpath: got '$got'"
echo "PASS noargs_classpath"

echo "OK — phase16_repl_classpath (3 cases) green"
