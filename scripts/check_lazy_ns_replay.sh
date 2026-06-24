#!/usr/bin/env bash
# scripts/check_lazy_ns_replay.sh — ADR-0163 D-516 isolated-replay gate.
#
# Proves every bundled bootstrap namespace loads CLEAN from its embedded bytecode
# region IN ISOLATION: a fresh `cljw` process (only the eager set loaded) does
# `(require 'ns)` and must exit 0. This is the completeness proof ADR-0163 §5 calls
# mandatory — it catches a LAZY ns that fails to load when required on its own (e.g.
# a future lib that calls a non-core var without declaring the `:require` its dep
# needs). The old eager-all monolith masked that class via FILES load order; lazy
# loading exposes it only for users who require in the "wrong" order, so a standing
# gate is the sole reliable defense.
#
# Eager nses (in bootstrap.EAGER_NS) require to a no-op — harmless to include, and
# testing ALL bundled nses keeps this gate drift-proof against EAGER_NS changes.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="zig-out/bin/cljw"
[ -x "$BIN" ] || { echo "building cljw…" >&2; zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null; }

fails=0
total=0
# Every bundled .clj → its ns name (RT resourceName munge inverse: '/'→'.', '_'→'-';
# clojure/core.clj is clojure.core). A fresh process per ns = genuine isolation.
while IFS= read -r f; do
    rel="${f#src/lang/clj/}"
    rel="${rel%.clj}"
    ns="$(printf '%s' "$rel" | tr '/' '.' | tr '_' '-')"
    total=$((total + 1))
    out="$(timeout 20 "$BIN" -e "(require '$ns)" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL lazy-replay [$ns]: exit $rc — $(printf '%s' "$out" | grep -iE 'error|exception' | head -1)"
        fails=$((fails + 1))
    fi
done < <(find src/lang/clj -name '*.clj' | sort)

if [ "$fails" -gt 0 ]; then
    echo "lazy-ns isolated replay: $fails/$total FAILED" >&2
    exit 1
fi
echo "lazy-ns isolated replay: $total/$total bundled namespaces load clean in isolation"
