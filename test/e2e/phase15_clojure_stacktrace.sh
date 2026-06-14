#!/usr/bin/env bash
# clojure.stacktrace backfill (D-273). A pure-Clojure namespace reimplemented over
# cljw's ex-info exception model (no JVM Throwable). root-cause + print-throwable +
# the cause-chain printing work; per-frame stack printing DEGRADES (cljw exposes no
# Clojure-level frame accessor for a caught exception — the trace data exists on the
# ExInfo but its Clojure surface is owned by the clojure.repl/pst work, D-232). The
# frame degradation is the accepted divergence AD-029. `print-trace-element` and the
# `*e`-dependent REPL helper `e` are intentionally omitted (documented in the ns).
# Uses the stdin-program form (`cljw -`) so only explicit (print …) output is
# captured (the `-e` form prints every top-level form's value, incl. require's nil).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# root-cause walks the ex-cause chain to the last cause.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.stacktrace)
(print (ex-message (clojure.stacktrace/root-cause (ex-info "outer" {} (ex-info "mid" {} (ex-info "inner" {}))))))
EOF
)
assert_eq 'root_cause' "$got" 'inner'

# root-cause of a single (uncaused) throwable is itself.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.stacktrace)
(print (ex-message (clojure.stacktrace/root-cause (ex-info "solo" {}))))
EOF
)
assert_eq 'root_cause_solo' "$got" 'solo'

# print-throwable: "<simple-class>: <message>" then the ex-data map on its own line.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.stacktrace)
(clojure.stacktrace/print-throwable (ex-info "boom" {:k 1}))
EOF
)
assert_eq 'print_throwable' "$got" 'ExceptionInfo: boom
{:k 1}'

# print-cause-trace: the throwable, the degraded no-frame marker, then the cause chain.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.stacktrace)
(clojure.stacktrace/print-cause-trace (ex-info "outer" {} (ex-info "inner" {})))
EOF
)
assert_eq 'print_cause_trace' "$got" 'ExceptionInfo: outer
{}
 at [no stack trace available]
Caused by: ExceptionInfo: inner
{}
 at [no stack trace available]'

assert_contains() {
    local name="$1"; local got="$2"; local needle="$3"
    [[ "$got" == *"$needle"* ]] || fail "$name: '$got' does not contain '$needle'"
    echo "PASS $name -> contains '$needle'"
}
assert_absent() {
    local name="$1"; local got="$2"; local needle="$3"
    [[ "$got" != *"$needle"* ]] || fail "$name: '$got' unexpectedly contains '$needle'"
    echo "PASS $name -> absent '$needle'"
}

# --- D2 (ADR-0140): a CAUGHT exception carries frames (ADR-0120), so
#     print-stack-trace prints per-frame `<ns>/<fn> (<file>:<line>)` lines
#     instead of the AD-029 marker. A constructed (never-thrown) ex-info has
#     NO frames, so it KEEPS the marker (the cases above stay green). ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.stacktrace)
(defn boom [] (/ 1 0))
(try (boom)
  (catch Throwable e
    (print (with-out-str (clojure.stacktrace/print-stack-trace e)))))
EOF
)
assert_contains 'caught_prints_user_frame' "$got" 'user/boom'
assert_absent   'caught_no_marker'         "$got" '[no stack trace available]'

# --- (stack-trace e): a cljw-shaped frame seq (maps {:ns :fn :file :line :column}),
#     innermost-first; :fn is the bare name, :ns separate. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn boom [] (/ 1 0))
(try (boom)
  (catch Throwable e
    (print (boolean (some #{"boom"} (map :fn (stack-trace e)))))))
EOF
)
assert_eq 'stack_trace_fn_key' "$got" 'true'

got=$("$BIN" - <<'EOF' 2>/dev/null
(defn boom [] (/ 1 0))
(try (boom)
  (catch Throwable e
    (print (boolean (some #{"user"} (map :ns (stack-trace e)))))))
EOF
)
assert_eq 'stack_trace_ns_key' "$got" 'true'

# --- a constructed ex-info (never thrown) has no frames → empty seq + marker kept. ---
got=$("$BIN" -e '(count (stack-trace (ex-info "x" {})))' 2>/dev/null)
assert_eq 'unthrown_no_frames' "$got" '0'

echo
echo "clojure.stacktrace backfill (D-273) + frame accessor (ADR-0140) e2e: all green."
