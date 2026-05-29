#!/usr/bin/env bash
# test/e2e/phase14_println_stdout.sh
#
# D-096 DISCHARGE regression — println/print/prn side-effect output now
# reaches stdout in -e mode and interleaves correctly with the runner's
# result-print. Root cause was two independent std.Io.File.stdout()
# writers (println's + runner's) each flushing from file offset 0, so the
# result-print clobbered the println output. Fix: a single shared
# rt.stdout writer (runtime.zig) the app entry points set and println/
# print/prn write through. These assertions FAILED before the fix
# (println output was lost; the runner's `nil` was all that survived).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_out() {
    local name="$1"; local expr="$2"; local want="$3"
    local got; got="$("$BIN" -e "$expr" 2>&1 || true)"
    [[ "$got" == "$want" ]] || fail "$name: got [$got] want [$want]"
    echo "PASS $name"
}

# println output appears, THEN the form's result (the runner's print)
assert_out 'println_then_result' '(do (println "hi") :ok)'            $'hi\n:ok'
assert_out 'multi_arg'           '(println 1 2 3)'                    $'1 2 3\nnil'
# print = no trailing newline; result follows on the same logical stream
assert_out 'print_no_newline'    '(do (print "x") (print "y") :z)'    'xy:z'
# prn = readable form (strings quoted)
assert_out 'prn_quotes'          '(prn "s")'                          $'"s"\nnil'
# multiple side-effect lines keep order and are NOT clobbered by the result
assert_out 'interleave_order'    '(do (println "a") (println "b") (println "c") :done)' $'a\nb\nc\n:done'
# the natural way to test an imperative loop (no def-accumulator needed)
assert_out 'dotimes_natural'     '(dotimes [i 3] (println i))'        $'0\n1\n2\nnil'
assert_out 'doseq_via_while'     '(do (def w 0) (while (< w 3) (println "w" w) (def w (inc w))) :end)' $'w 0\nw 1\nw 2\n:end'

echo "OK — phase14_println_stdout smoke (7 cases) green"
