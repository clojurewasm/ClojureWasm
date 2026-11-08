#!/usr/bin/env bash
# test/e2e/phase16_repl_classpath.sh — the interactive REPL is classpath-aware:
# `(require 'my.lib)` at a REPL prompt resolves `my/lib.clj` off the classpath,
# for all THREE REPL entry paths (D-322): `cljw -cp DIR` (flags-but-no-source),
# `cljw repl` + $CLJW_PATH (subcommand), and bare `cljw` + $CLJW_PATH (no-args).
# Before this fix none of the three threaded load_paths into repl.run, so a REPL
# require only saw the embedded resolver — no filesystem classpath.
#
# Cases (d)-(f) pin the `repl` subcommand's own arg surface (the D-322
# residual, closed after Discussion #13 landed the same surface on nrepl):
# `repl [-cp <dirs>] [-A:alias…]`, with unknown args REJECTED — before, every
# trailing arg was silently ignored, so `cljw repl -cp src` dropped the -cp
# without a diagnostic. scripts/check_entrypoint_surface.sh guards the
# per-entry-point parity contract this file exercises for repl.
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

# (d) `cljw repl -cp DIR` — the -cp flag on the subcommand itself.
got=$(printf '%s\n' "$PROG" | "$BIN" repl -cp "$CP" 2>/dev/null)
[[ "$got" == *hello-from-classpath* ]] || fail "repl_cp_flag: got '$got'"
echo "PASS repl_cp_flag"

# (e) `cljw repl -A:extra` — a deps.edn alias's :extra-paths joins the
# classpath, same as the run/build path.
PROJ=$(mktemp -d)
trap 'rm -rf "$CP" "$PROJ"' EXIT
mkdir -p "$PROJ/xsrc/my2"
cat > "$PROJ/xsrc/my2/lib2.clj" <<'CLJ'
(ns my2.lib2)
(defn greet [] "hello-from-alias-path")
CLJ
cat > "$PROJ/deps.edn" <<'EOF'
{:aliases {:extra {:extra-paths ["xsrc"]}}}
EOF
PROG2='(require (quote my2.lib2)) (println (my2.lib2/greet))'
ABS_BIN="$(pwd)/$BIN"
got=$(cd "$PROJ" && printf '%s\n' "$PROG2" | "$ABS_BIN" repl -A:extra 2>/dev/null)
[[ "$got" == *hello-from-alias-path* ]] || fail "repl_alias_extra_paths: got '$got'"
echo "PASS repl_alias_extra_paths"

# (f) unknown args are rejected, not silently ignored.
if printf '' | "$BIN" repl --bogus >/tmp/repl_bogus.$$ 2>&1; then
    rm -f /tmp/repl_bogus.$$
    fail "repl_unknown_arg: --bogus was accepted"
fi
grep -q "unknown argument" /tmp/repl_bogus.$$ || { cat /tmp/repl_bogus.$$; rm -f /tmp/repl_bogus.$$; fail "repl_unknown_arg: no diagnostic"; }
rm -f /tmp/repl_bogus.$$
echo "PASS repl_unknown_arg -> rejected"

echo "OK — phase16_repl_classpath (6 cases) green"
