#!/usr/bin/env bash
# scripts/check_corpus_regression.sh — replay the clj-diff corpus through cljw.
#
# Every `test/diff/clj_corpus/*.txt` holds golden `expr` / `;;=> <output>`
# pairs captured by `scripts/clj_diff_sweep.sh --corpus` at the moment cljw
# matched the clj oracle. This check re-runs each `expr` through cljw ONLY
# (no clj, no network) and fails if the output drifts from the stored
# `;;=>`. That makes a discharged "X/Y landed" debt claim mechanically
# re-checkable (anti D-177 false-positive-discharge), and catches plain
# regressions in landed behaviour.
#
# Usage: bash scripts/check_corpus_regression.sh        # all corpora
#        bash scripts/check_corpus_regression.sh seqfns # one corpus stem
#
# Exit 0 = all golden outputs reproduced; 1 = at least one drift / error.

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="zig-out/bin/cljw"
[ -x "$BIN" ] || { echo "building cljw…" >&2; zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null; }

dir="test/diff/clj_corpus"
if [ ! -d "$dir" ]; then
    echo "no corpus directory ($dir) — nothing to check"
    exit 0
fi

if [ $# -gt 0 ]; then
    files=("$dir/$1.txt")
else
    files=("$dir"/*.txt)
fi

total=0
fails=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    expr=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|';;'*'=> '*)
                if [ -n "$expr" ] && [ "${line#';;=> '}" != "$line" ]; then
                    want="${line#';;=> '}"
                    got="$(timeout 20 "$BIN" -e "(prn $expr)" 2>&1 | head -1)"
                    total=$((total + 1))
                    if [ "$got" != "$want" ]; then
                        printf 'DRIFT [%s] %s\n   want=[%s]\n    got=[%s]\n' "$(basename "$f" .txt)" "$expr" "$want" "$got"
                        fails=$((fails + 1))
                    fi
                    expr=""
                fi
                ;;
            ';'*) : ;;            # other comment line — ignore
            *) expr="$line" ;;    # an expression line
        esac
    done < "$f"
done

echo "corpus regression: $((total - fails))/$total golden outputs reproduced"
[ "$fails" -eq 0 ]
