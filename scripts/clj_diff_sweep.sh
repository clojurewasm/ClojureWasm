#!/usr/bin/env bash
# scripts/clj_diff_sweep.sh — F-011 differential sweep harness.
#
# Runs each Clojure VALUE expression through both `clj` (the oracle) and
# `cljw`, then reports OK / DIFF per expression. This is the mechanised
# form of the manual `for e in …; cljw vs clj` loops the quality loop kept
# hand-writing (see `.claude/rules/clj_diff_sweep.md`).
#
# Usage:
#   bash scripts/clj_diff_sweep.sh EXPRS_FILE        # one bare expr per line
#   printf '%s\n' '(+ 1 2)' '(map inc [1])' | bash scripts/clj_diff_sweep.sh -
#   bash scripts/clj_diff_sweep.sh EXPRS_FILE --corpus regex   # append OKs
#
# Input format: ONE value-producing expression per line, NOT wrapped in
# `prn` (the harness wraps it). Blank lines and `;`-comment lines are
# skipped. Example file:
#   (map inc [1 2 3])
#   (clojure.string/upper-case "ab")
#
# Methodology (memory `clj_diff_sweep_methodology` + this header):
#   - clj is run ONCE over a batch (one `(prn EXPR)` per line) — fast, and
#     a multi-line clj error never desyncs the line mapping because each
#     prn is on its own line.
#   - cljw is run ONE expression at a time (`cljw -e '(prn EXPR)'`, line 1)
#     — per-expr is the reliable cljw surface; a batch would interleave.
#   - Both are `timeout`-wrapped (orphan_prevention.md). Bound any seq
#     producer with `(take N …)`; an unbounded `(range)` realises forever.
#   - SET / MAP literals print in hash order, which legitimately differs
#     from clj — a `#{…}` / non-sorted `{…}` DIFF is usually NOT a bug.
#     Check F-NNN (project_facts) before "fixing" an apparent divergence
#     (e.g. `+`/`*` overflow auto-promote is INTENTIONAL per F-005).
#
# Exit code: 0 if every expression matched, 1 if any DIFF (so it can gate
# a corpus regression run).

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="zig-out/bin/cljw"
CLJ="${CLJ:-clj}"
CORPUS=""

src="${1:-}"
if [ -z "$src" ]; then
    echo "usage: clj_diff_sweep.sh <exprs-file|-> [--corpus NAME]" >&2
    exit 2
fi
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --corpus) CORPUS="${2:-}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -x "$BIN" ] || { echo "building cljw…" >&2; zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null; }

# Read non-blank, non-comment lines into an array.
exprs=()
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|';'*) continue ;;
        *) exprs+=("$line") ;;
    esac
done < <([ "$src" = "-" ] && cat || cat "$src")

n=${#exprs[@]}
[ "$n" -gt 0 ] || { echo "no expressions" >&2; exit 2; }

# --- clj batch (one prn per line) ---
# A qualified symbol like `clojure.set/union` needs its namespace required
# first — clj does NOT auto-load it, and an un-required reference aborts the
# WHOLE batch at line 1 (every later prn then maps to <clj-missing>, a false
# all-DIFF signal). Auto-detect every `dotted.ns/` prefix in the exprs and
# emit a require ahead of the prn lines. The requires are NOT prn-wrapped, so
# they add no stdout line and the clj_lines[i] ↔ exprs[i] mapping is preserved.
# A non-requireable prefix (e.g. a Java FQCN `java.util.UUID/…`) is swallowed
# by the try/catch so it never aborts the batch — Java classes need no require.
batch="$(mktemp /tmp/clj_diff_batch.XXXXXX.clj)"
trap 'rm -f "$batch"' EXIT
nses="$(printf '%s\n' "${exprs[@]}" \
    | grep -oE '[a-zA-Z][a-zA-Z0-9._-]*\.[a-zA-Z0-9._-]+/' \
    | sed 's:/$::' | sort -u)"
for ns in $nses; do
    printf "(try (require '%s) (catch Throwable _ nil))\n" "$ns" >> "$batch"
done
# Each form is try/catch-wrapped so an expr that THROWS (an error-case probe,
# e.g. a multimethod no-match) prints one `<clj-error> <Class>` line instead
# of aborting the rest of the single-process batch (which would map every
# later expr to <clj-missing>). One output line per expr preserves the
# clj_lines↔exprs mapping; cljw's error line will DIFF (format differs by
# design — compare the exception CLASS, not the message, per F-011).
for e in "${exprs[@]}"; do
    printf '(try (prn %s) (catch Throwable e (println (str "<clj-error> " (.getName (class e))))))\n' "$e" >> "$batch"
done
clj_out="$(timeout 60 "$CLJ" -M "$batch" 2>/dev/null)"
mapfile -t clj_lines <<< "$clj_out"

# --- per-expr cljw + compare ---
fails=0
ok_exprs=()
ok_outs=()
for i in $(seq 0 $((n - 1))); do
    e="${exprs[$i]}"
    cj="${clj_lines[$i]:-<clj-missing>}"
    cw="$(timeout 20 "$BIN" -e "(prn $e)" 2>&1 | head -1)"
    if [ "$cw" = "$cj" ]; then
        printf 'OK   %s\n' "$e"
        ok_exprs+=("$e")
        ok_outs+=("$cw")
    else
        printf 'DIFF %s\n       cljw=[%s]\n        clj=[%s]\n' "$e" "$cw" "$cj"
        fails=$((fails + 1))
    fi
done

echo "---"
echo "$((n - fails))/$n matched, $fails diff(s)"

# Corpus golden pairs (`expr` then `;;=> <output>`) — only confirmed (cljw ==
# clj) lines. The regression check (scripts/check_corpus_regression.sh) re-runs
# cljw against the stored `;;=>` value, so it is cljw-only / clj-free / gateable.
if [ -n "$CORPUS" ] && [ "${#ok_exprs[@]}" -gt 0 ]; then
    dir="test/diff/clj_corpus"
    mkdir -p "$dir"
    f="$dir/$CORPUS.txt"
    for i in $(seq 0 $((${#ok_exprs[@]} - 1))); do
        printf '%s\n;;=> %s\n' "${ok_exprs[$i]}" "${ok_outs[$i]}" >> "$f"
    done
    echo "appended ${#ok_exprs[@]} golden pair(s) to $f"
fi

[ "$fails" -eq 0 ]
