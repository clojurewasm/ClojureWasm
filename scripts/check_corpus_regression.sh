#!/usr/bin/env bash
# scripts/check_corpus_regression.sh — replay the clj-diff corpus through cljw.
#
# Every `test/diff/clj_corpus/*.txt` (general behaviour) and
# `test/diff/class_corpus/*.txt` (F-014/ADR-0136 per-class Java completeness)
# holds golden `expr` / `;;=> <output>` pairs captured by
# `scripts/clj_diff_sweep.sh --corpus` / `--class-corpus` at the moment cljw
# matched the clj oracle. This check re-runs each `expr` through cljw ONLY
# (no clj, no network) and fails if the output drifts from the stored
# `;;=>`. That makes a discharged "X/Y landed" debt claim mechanically
# re-checkable (anti D-177 false-positive-discharge), and catches plain
# regressions in landed behaviour. For class_corpus it also locks per-class
# Java surface completeness: a method clj answers and cljw stops answering
# (or drifts) fails the gate.
#
# Usage: bash scripts/check_corpus_regression.sh        # all corpora
#        bash scripts/check_corpus_regression.sh seqfns # one corpus stem
#        bash scripts/check_corpus_regression.sh String # one class corpus stem
#
# Exit 0 = all golden outputs reproduced; 1 = at least one drift / error.

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="zig-out/bin/cljw"
[ -x "$BIN" ] || { echo "building cljw…" >&2; zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null; }

# Both the general behaviour corpus and the per-class Java-completeness
# corpus (F-014/ADR-0136) are gated. A given stem is looked up in both dirs.
dirs=("test/diff/clj_corpus" "test/diff/class_corpus")

files=()
if [ $# -gt 0 ]; then
    for d in "${dirs[@]}"; do files+=("$d/$1.txt"); done
else
    for d in "${dirs[@]}"; do
        [ -d "$d" ] && files+=("$d"/*.txt)
    done
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo "no corpus directories (${dirs[*]}) — nothing to check"
    exit 0
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
