#!/usr/bin/env bash
# scripts/mutation/run.sh — Layer 8 (Mutation) sweep. ADR-0186.
#
# Changes one line of one source file, rebuilds, runs a suite, and records
# whether anything failed. A mutant the suite still passes is a SURVIVOR: that
# line's behaviour is unconstrained by that suite.
#
# WHICH suite is `--oracle`, and the score means nothing without it:
#   unit         (default) inline Zig tests + Layer 7 properties.
#   unit+golden  also renders the Layer 6 cases. Required for any file whose
#                behaviour is what the program PRINTS — under `unit` a golden
#                case cannot kill a mutant, so a printing path scores as
#                unconstrained no matter how many snapshots pin it.
#
# On demand only, never in a gate. One rebuild per mutant, so `--budget` is the
# number of rebuilds bought.
#
# ISOLATION: the sweep NEVER touches your checkout. It creates a detached git
# worktree at a chosen revision, mutates files there, and removes it at the end.
#
# Usage:
#   bash scripts/mutation/run.sh --targets src/runtime/collection/set.zig
#   bash scripts/mutation/run.sh --targets a.zig,b.zig --budget 20 --seed 7
#   bash scripts/mutation/run.sh --targets-from .dev/mutation_targets.txt --rev v1.10.1
#   bash scripts/mutation/run.sh --targets v.zig --ids 1a2b3c,4d5e6f   # re-run named mutants
#   bash scripts/mutation/run.sh --targets src/runtime/print.zig --oracle unit+golden
#
# Output: a JSONL log plus a markdown summary under .dev/mutation/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd)
# A mutant rebuild shares this machine's `.zig-cache` with any gate running in
# the main tree; take the same lock `test/cljw-test` takes.
source "$REPO_ROOT/scripts/lib_build_lock.sh"

TARGETS=""
TARGETS_FILE=""
BUDGET=15
SEED=0
IDS=""
REV="HEAD"
OUT_DIR="$REPO_ROOT/.dev/mutation"
EQUIV_FILE="$REPO_ROOT/.dev/mutation_equivalent.jsonl"
ALIASES_FILE="$REPO_ROOT/.dev/mutation_id_aliases.jsonl"
BUILD_ARGS="-Dwasm -Doptimize=Debug"
# A timeout counts as KILLED.
PER_MUTANT_TIMEOUT=900
# Which suite decides "killed". `unit` is the inline Zig tests + properties;
# `unit+golden` also renders the Layer 6 cases, so a mutation in a printing
# path is reachable. See `run_oracle`.
ORACLE="unit"

while [ $# -gt 0 ]; do
    case "$1" in
        --targets) TARGETS="$2"; shift ;;
        --targets-from) TARGETS_FILE="$2"; shift ;;
        --budget) BUDGET="$2"; shift ;;
        --ids) IDS="$2"; shift ;;
        --seed) SEED="$2"; shift ;;
        --rev) REV="$2"; shift ;;
        --out) OUT_DIR="$2"; shift ;;
        --equivalent) EQUIV_FILE="$2"; shift ;;
        --aliases) ALIASES_FILE="$2"; shift ;;
        --build-args) BUILD_ARGS="$2"; shift ;;
        --timeout) PER_MUTANT_TIMEOUT="$2"; shift ;;
        --oracle) ORACLE="$2"; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$TARGETS_FILE" ]; then
    TARGETS=$(grep -v '^\s*#' "$TARGETS_FILE" | grep -v '^\s*$' | paste -sd, -)
fi
[ -n "$TARGETS" ] || { echo "nothing to mutate: pass --targets or --targets-from" >&2; exit 2; }

# Validated here, not in run_oracle: there the message would land in the
# redirected baseline log and a typo would read as a red baseline.
case "$ORACLE" in
    unit|unit+golden) ;;
    *) echo "unknown --oracle: $ORACLE (unit | unit+golden)" >&2; exit 2 ;;
esac

# Portable bounded run (check_portable_timeout.sh: no bare `timeout`).
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

# The kill oracle. ONE definition, used for both the baseline and every mutant —
# a baseline measured by a different suite than the mutants would report every
# mutant as killed.
run_oracle() {
    local wt="$1"
    case "$ORACLE" in
        unit)
            ( cd "$wt" && with_build_lock run_bounded "$PER_MUTANT_TIMEOUT" zig build test $BUILD_ARGS )
            ;;
        unit+golden)
            ( cd "$wt" \
                && with_build_lock run_bounded "$PER_MUTANT_TIMEOUT" zig build test $BUILD_ARGS \
                && with_build_lock run_bounded "$PER_MUTANT_TIMEOUT" zig build $BUILD_ARGS \
                && CLJW_SKIP_BUILD=1 CLJW_BIN="$wt/zig-out/bin/cljw" \
                   run_bounded "$PER_MUTANT_TIMEOUT" bash test/golden/run.sh )
            ;;
        *)
            echo "unknown --oracle: $ORACLE (unit | unit+golden)" >&2; exit 2 ;;
    esac
}

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/cljw-mutation-XXXXXX")
case "$WORKTREE" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "refusing to mutate inside the repository: $WORKTREE" >&2; exit 1 ;;
esac

cleanup() {
    cd "$REPO_ROOT"
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
}
trap cleanup EXIT

echo "mutation: worktree $WORKTREE at $REV"
git worktree add --detach "$WORKTREE" "$REV" >/dev/null

mkdir -p "$OUT_DIR"
STAMP=$(git rev-parse --short "$REV")
# The oracle is part of the identity of a run: a score from `unit` and a score
# from `unit+golden` are answers to different questions and must not share a name.
SLUG="$STAMP-seed$SEED"
[ "$ORACLE" = unit ] || SLUG="$SLUG-$(printf '%s' "$ORACLE" | tr '+' '-')"
LOG="$OUT_DIR/mutants-$SLUG.jsonl"
REPORT="$OUT_DIR/report-$SLUG.md"
: > "$LOG"

# --- baseline -------------------------------------------------------------
echo "mutation: baseline build + test via oracle '$ORACLE' (this must pass) …"
if ! run_oracle "$WORKTREE" >"$OUT_DIR/baseline.log" 2>&1; then
    echo "mutation: BASELINE FAILED at $REV — fix the suite before measuring it." >&2
    tail -20 "$OUT_DIR/baseline.log" >&2
    exit 1
fi
echo "mutation: baseline green"

# --- enumerate + sample ---------------------------------------------------
ALL_MUTANTS="$OUT_DIR/candidates-$STAMP.jsonl"
: > "$ALL_MUTANTS"
IFS=',' read -ra TARGET_LIST <<< "$TARGETS"
for t in "${TARGET_LIST[@]}"; do
    [ -f "$WORKTREE/$t" ] || { echo "mutation: no such target $t" >&2; exit 2; }
    ( cd "$WORKTREE" && python3 "$REPO_ROOT/scripts/mutation/mutate.py" list "$t" --aliases "$ALIASES_FILE" ) >> "$ALL_MUTANTS"
done

TOTAL=$(wc -l < "$ALL_MUTANTS" | tr -d ' ')
SAMPLE="$OUT_DIR/sample-$STAMP-seed$SEED.jsonl"
python3 - "$ALL_MUTANTS" "$SAMPLE" "$BUDGET" "$SEED" "$IDS" <<'PY'
import json, random, sys
src, dst, budget, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ids = [i for i in sys.argv[5].split(",") if i] if len(sys.argv) > 5 else []
rows = [json.loads(l) for l in open(src) if l.strip()]
if ids:
    by_id = {}
    for row in rows:
        for ident in [row["id"], *row.get("aliases", [])]:
            if ident in by_id and by_id[ident]["id"] != row["id"]:
                raise SystemExit("ambiguous mutant id: " + ident)
            by_id[ident] = row
    missing = [i for i in ids if i not in by_id]
    if missing:
        raise SystemExit("mutants no longer present (did the file change?): " + ", ".join(missing))
    rows = [dict(by_id[i], selected_id=i) for i in ids]
    budget = 0
if budget and len(rows) > budget:
    rows = random.Random(seed).sample(rows, budget)
rows.sort(key=lambda r: (r["file"], r["line"], r["col"]))
with open(dst, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
print(f"mutation: {len(rows)} of {len(open(src).readlines())} candidates selected")
PY

# --- run ------------------------------------------------------------------
killed=0; survived=0; unviable=0; n=0
SELECTED=$(wc -l < "$SAMPLE" | tr -d ' ')

while IFS= read -r row; do
    n=$((n + 1))
    id=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
    file=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file"])')
    op=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["op"])')
    line=$(printf '%s' "$row" | python3 -c 'import json,sys;print(json.load(sys.stdin)["line"])')

    ( cd "$WORKTREE" && git checkout -- "$file" )
    ( cd "$WORKTREE" && python3 "$REPO_ROOT/scripts/mutation/mutate.py" apply "$file" "$id" >/dev/null )

    set +e
    run_oracle "$WORKTREE" >"$OUT_DIR/mutant-$id.log" 2>&1
    rc=$?
    set -e

    if [ $rc -eq 0 ]; then
        verdict=survived; survived=$((survived + 1))
    elif grep -qE "^(src/|/).*error: " "$OUT_DIR/mutant-$id.log" && \
         ! grep -q "test failure" "$OUT_DIR/mutant-$id.log"; then
        # Did not compile: says nothing about the suite.
        verdict=unviable; unviable=$((unviable + 1))
        rm -f "$OUT_DIR/mutant-$id.log"
    else
        verdict=killed; killed=$((killed + 1))
        rm -f "$OUT_DIR/mutant-$id.log"
    fi

    printf '%s\n' "$row" | python3 -c "
import json, sys
row = json.load(sys.stdin)
row['verdict'] = '$verdict'
print(json.dumps(row))
" >> "$LOG"

    printf '  [%d/%d] %-9s %s:%s %s\n' "$n" "$SELECTED" "$verdict" "$file" "$line" "$op"
done < "$SAMPLE"

( cd "$WORKTREE" && git checkout -- . )

# --- report ---------------------------------------------------------------
# Survivors are reclassified against the equivalence register.
set +e
python3 "$REPO_ROOT/scripts/mutation/report.py" \
    --log "$LOG" --report "$REPORT" --stamp "$STAMP" --seed "$SEED" \
    --total "$TOTAL" --candidates "$ALL_MUTANTS" --equivalent "$EQUIV_FILE"
report_rc=$?
set -e

echo "mutation: oracle=$ORACLE raw verdicts killed=$killed survived=$survived unviable=$unviable (log: $LOG)"
exit $report_rc
