#!/usr/bin/env bash
# test/e2e/phase14_cljw_build.sh
#
# Phase 14 §9.16 row 14.11 — D-100(b) `cljw build`. Compile a Clojure
# source to a serialized bytecode payload embedded in a copy of the cljw
# binary (Deno-style "CLJC" trailer, ADR-0034 + amendment 1/2), then run
# the produced self-contained binary. Exercises:
#   - fn_val constant serialization (the `greet` fn — ADR-0034 am2)
#   - the interleaved per-chunk startup run (chunk 2 calls `greet` def'd
#     in chunk 1 — EnvelopeIterator)
#   - the `"CLJC"` artifact trailer (frame/extract)
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/app.clj" <<'CLJ'
(def greet (fn* [name] (str "hello, " name)))
(println (greet "world"))
CLJ

OUT="$TMP/app"

# Build: compile app.clj into a self-contained binary at $OUT.
"$BIN" build "$TMP/app.clj" -o "$OUT" >/dev/null

# (1) The artifact ends with the "CLJC" trailer magic.
footer=$(tail -c 4 "$OUT")
[[ "$footer" == "CLJC" ]] || fail "trailer_magic: tail -c4 = '$footer', want 'CLJC'"
echo "PASS trailer_magic -> CLJC"

# (2) The produced binary is executable and runs its embedded payload.
[[ -x "$OUT" ]] || fail "executable_bit: $OUT is not executable"
got=$("$OUT")
[[ "$got" == "hello, world" ]] || fail "embedded_run: got '$got', want 'hello, world'"
echo "PASS embedded_run -> hello, world"

# (3) The plain cljw binary (no trailer) is unaffected — still a REPL/-e
#     driver, not an embedded-payload runner.
plain=$("$BIN" -e '(+ 1 2)')
[[ "$plain" == "3" ]] || fail "plain_unaffected: got '$plain', want '3'"
echo "PASS plain_unaffected -> 3"

# (4) Multi-line stdout must be ordered + complete. Regression for the
#     embedded-run stdout bug: tryRunEmbedded left rt.stdout null, so each
#     println built a fresh offset-tracking writer that restarted at offset 0
#     and overwrote prior lines (garbled / reordered / missing output). Routing
#     through the one process-shared writer (+ flush) fixes it.
cat >"$TMP/multi.clj" <<'CLJ'
(println "line-1")
(println "line-2" (+ 1 2))
(println "line-3")
CLJ
"$BIN" build "$TMP/multi.clj" -o "$TMP/multi" >/dev/null
got_multi=$("$TMP/multi")
want_multi=$'line-1\nline-2 3\nline-3'
[[ "$got_multi" == "$want_multi" ]] || fail "multiline_ordered: got '$got_multi', want '$want_multi'"
echo "PASS multiline_ordered -> 3 lines, ordered + complete"

# (5) Multi-file app: a `(require '[lib])` over a `-cp` classpath. D-356
#     require-closure embedding (ADR-0034 amendment 3): the build resolves the
#     lib off the classpath (Part 1) AND embeds the lib's defining chunks ahead
#     of the entry's require chunk (Part 2), so the produced binary runs
#     self-contained with NO runtime classpath. The lib's `(defn hello …)` is an
#     fn_val constant carried by the closure chunks.
mkdir -p "$TMP/libsrc/mylib"
cat >"$TMP/libsrc/mylib/greet.clj" <<'CLJ'
(ns mylib.greet)
(defn hello [] "hi from mylib")
CLJ
cat >"$TMP/caller.clj" <<'CLJ'
(require '[mylib.greet :as g])
(println (g/hello))
CLJ
"$BIN" build "$TMP/caller.clj" -o "$TMP/caller" -cp "$TMP/libsrc" >/dev/null
# Run from a directory with NO classpath/lib in sight — proves self-containment.
mkdir -p "$TMP/empty"
got_cp=$(cd "$TMP/empty" && "$TMP/caller")
[[ "$got_cp" == "hi from mylib" ]] || fail "classpath_require: got '$got_cp', want 'hi from mylib'"
echo "PASS classpath_require -> hi from mylib"

# (6) Same multi-file app via the CLJW_PATH env classpath (instead of -cp).
CLJW_PATH="$TMP/libsrc" "$BIN" build "$TMP/caller.clj" -o "$TMP/caller2" >/dev/null
got_path=$(cd "$TMP/empty" && "$TMP/caller2")
[[ "$got_path" == "hi from mylib" ]] || fail "cljw_path_require: got '$got_path', want 'hi from mylib'"
echo "PASS cljw_path_require -> hi from mylib"

# (7) Main mode `cljw build -m <ns>` (ADR-0034 am4, D-363): the binary invokes
#     `(<ns>/-main args)` at RUN — NOT at build. A top-level form in the ns runs
#     at build (closure capture) AND at run, but `-main` is only CALLED at run.
mkdir -p "$TMP/appsrc"
cat >"$TMP/appsrc/myapp.clj" <<'CLJ'
(ns myapp)
(println "myapp top-level")
(defn -main [& args] (println "main:" (vec args)))
CLJ
build_out=$("$BIN" build -m myapp -o "$TMP/myapp" -cp "$TMP/appsrc")
# Build evals the require (top-level runs) but must NOT call -main.
[[ "$build_out" == "myapp top-level" ]] || fail "main_build_no_invoke: build out '$build_out', want only 'myapp top-level' (no -main)"
case "$build_out" in *"main:"*) fail "main_build_no_invoke: build called -main";; esac
echo "PASS main_build_no_invoke -> -main NOT called at build"

# (8) Running the main-mode binary calls -main (after the ns top-level).
got_main=$(cd "$TMP/empty" && "$TMP/myapp")
want_main=$'myapp top-level\nmain: []'
[[ "$got_main" == "$want_main" ]] || fail "main_run: got '$got_main', want '$want_main'"
echo "PASS main_run -> top-level then (-main)"

# (9) The binary's own runtime argv reaches -main (`./out 8080 foo`).
got_argv=$(cd "$TMP/empty" && "$TMP/myapp" 8080 foo)
want_argv=$'myapp top-level\nmain: [8080 foo]'
[[ "$got_argv" == "$want_argv" ]] || fail "main_runtime_argv: got '$got_argv', want '$want_argv'"
echo "PASS main_runtime_argv -> [8080 foo]"

# (10) A multi-file -m app: the entry ns requires a lib; the closure + the
#      -main invocation both embed, run self-contained.
mkdir -p "$TMP/appsrc/svc"
cat >"$TMP/appsrc/svc/core.clj" <<'CLJ'
(ns svc.core (:require [mylib.greet :as g]))
(defn -main [& _] (println (g/hello) "from -main"))
CLJ
"$BIN" build -m svc.core -o "$TMP/svc" -cp "$TMP/appsrc:$TMP/libsrc" >/dev/null
got_svc=$(cd "$TMP/empty" && "$TMP/svc")
[[ "$got_svc" == "hi from mylib from -main" ]] || fail "main_multifile: got '$got_svc', want 'hi from mylib from -main'"
echo "PASS main_multifile -> hi from mylib from -main"

# (11) deps.edn `:main-opts` drives the build entry (ADR-0034 am4 A4-D4): no
#      explicit `-m`, a selected alias's `:main-opts ["-m" <ns>]` supplies it
#      (mirrors `cljw -M:alias`). Build runs from a cwd with the deps.edn.
mkdir -p "$TMP/proj/server/myapp"
cat >"$TMP/proj/server/myapp/core.clj" <<'CLJ'
(ns myapp.core)
(defn -main [& args] (println "via main-opts:" (vec args)))
CLJ
cat >"$TMP/proj/deps.edn" <<'EDN'
{:paths ["."]
 :aliases {:run {:extra-paths ["server"] :main-opts ["-m" "myapp.core"]}}}
EDN
bin_abs="$PWD/$BIN" # build runs from $TMP/proj (to read its deps.edn), so the binary path must be absolute
( cd "$TMP/proj" && "$bin_abs" build -A:run -o "$TMP/mo" ) >/dev/null
got_mo=$(cd "$TMP/empty" && "$TMP/mo" 7)
[[ "$got_mo" == "via main-opts: [7]" ]] || fail "main_opts_drive: got '$got_mo', want 'via main-opts: [7]'"
echo "PASS main_opts_drive -> via main-opts: [7]"

echo "ALL phase14_cljw_build PASS"
