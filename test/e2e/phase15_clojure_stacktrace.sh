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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

echo
echo "clojure.stacktrace backfill (D-273) e2e: all green."
