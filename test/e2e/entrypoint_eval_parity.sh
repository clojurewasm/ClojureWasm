#!/usr/bin/env bash
# test/e2e/entrypoint_eval_parity.sh — the entry-point differential oracle.
#
# cljw evaluates user code through several entry points (`-e`, a script file,
# stdin, `repl`, `nrepl`, and `build`+run). They are supposed to be the same
# language. Twice now they were not, and both times a real user found it:
#
#   Discussion #13 — `nrepl` never resolved the filesystem classpath, so
#                    `(require '[my.lib])` worked everywhere except in an
#                    editor session (D-322 landed on repl.run only).
#   Discussion #14 — `nrepl` and `repl` analysed a whole top-level `(do …)`
#                    before running any of it, so a `require` beside its first
#                    use failed (D-374's unroll landed on runner.runSource
#                    only). `cljw build` had the same gap, unreported.
#
# Both are one class: a shared-engine capability that some entry point does not
# reach. The class is invisible to per-entry-point tests, because each entry
# point's own suite passes — what is wrong is that they DISAGREE. So this file
# is a differential oracle, the same shape as the dual-backend one the unit
# tests carry (F-012): run each program through EVERY entry point and require
# identical output. No expected value is written down; the entry points are
# each other's oracle, which is why a future divergence fails here without
# anyone having predicted its shape.
#
# The comparison surface is what a program PRINTS with the `RESULT` marker, not
# raw stdout: whether an entry point also echoes each form's value is a contract
# difference, not a language one (`cljw -e` echoes, a script file does not —
# `clj` behaves the same way). Filtering to marked lines compares the part that
# must agree, and an entry point that fails outright still diverges loudly,
# because it prints no marked line at all.
#
# Adding an entry point: add a runner function + its name to ENTRY_POINTS.
# Adding a case: append to PROGRAMS. Programs must be deterministic, print
# their result with `(println "RESULT" …)`, and finish quickly.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BIN="$ROOT/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

# Portable bounded run: GNU `timeout`, else coreutils `gtimeout`, else
# unbounded (hosted mac runners ship neither) — the same helper the http e2e
# steps use; check_portable_timeout.sh gates the bare-`timeout` form.
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A throwaway project so `require` of a PROJECT namespace (not just a bundled
# one) is exercised: that is the half of Discussion #13 a bundled-only require
# would have missed.
mkdir -p "$WORK/src/parity_probe"
cat > "$WORK/src/parity_probe/lib.clj" <<'CLJ'
(ns parity-probe.lib)
(defn answer [] 42)
CLJ

# --- The programs. One per line-block; each prints exactly one line. ---
# Named so a failure says what diverged, not just "case 3".
PROGRAMS=(
    "toplevel_do_bundled_require|(do (require (quote [clojure.string :as s])) (println \"RESULT\" (s/upper-case \"ok\")))"
    "toplevel_do_project_require|(do (require (quote [parity-probe.lib :as p])) (println \"RESULT\" (p/answer)))"
    "toplevel_do_nested|(do (do (require (quote [clojure.set :as st])) (println \"RESULT\" (st/union #{1} #{2}))))"
    "toplevel_do_defmacro_then_use|(do (defmacro m2 [] 42) (println \"RESULT\" (m2)))"
    "separate_forms_require_then_use|(require (quote [clojure.string :as s2])) (println \"RESULT\" (s2/lower-case \"AB\"))"
    "project_require_bare|(require (quote [parity-probe.lib :as p2])) (println \"RESULT\" (p2/answer))"
    "plain_arithmetic|(println \"RESULT\" (+ 1 2))"
    "def_then_use|(def x9 7) (println \"RESULT\" (* x9 6))"
)

# --- Entry-point runners. Each takes the program text, echoes its stdout. ---
# All run with cwd = $WORK and the project on the classpath, so every entry
# point gets the same resolution context; how it is SPELLED per entry point is
# part of what is under test.

run_e_flag() {
    (cd "$WORK" && CLJW_PATH=src run_bounded 30 "$BIN" -e "$1" 2>&1)
}

run_file() {
    printf '%s\n' "$1" > "$WORK/prog.clj"
    (cd "$WORK" && CLJW_PATH=src run_bounded 30 "$BIN" prog.clj 2>&1)
}

run_stdin() {
    (cd "$WORK" && printf '%s\n' "$1" | CLJW_PATH=src run_bounded 30 "$BIN" - 2>&1)
}

run_repl() {
    # The REPL echoes a banner and `user=>` prompts around the output; strip
    # them so the comparison is on the program's own output.
    (cd "$WORK" && printf '%s\n' "$1" | run_bounded 30 "$BIN" repl -cp src 2>&1) \
        | sed -e 's/^user=> //' -e '/^Wasm REPL/d' -e '/^user=>$/d' \
        | grep -v '^$' || true
}

run_build() {
    # A FRESH output path per case. Writing a new executable over the same path
    # keeps the inode, and macOS then SIGKILLs the re-run binary ("Killed: 9")
    # because the cached code signature no longer matches its contents — which
    # looks exactly like cljw crashing, in the entry point least able to
    # distinguish the two. Unique names cost nothing and remove the question.
    local out="prog_bin_${build_seq}"
    build_seq=$((build_seq + 1))
    printf '%s\n' "$1" > "$WORK/prog.clj"
    (cd "$WORK" && run_bounded 180 "$BIN" build prog.clj -o "$out" -cp src >/dev/null 2>&1) || {
        echo "BUILD-FAILED"; return 0
    }
    (cd "$WORK" && run_bounded 30 "./$out" 2>&1)
}

# Reap the nREPL server for a port. `kill $!` is NOT enough: `( cd … && cmd ) &`
# leaves bash a real subshell (two commands, so no exec-optimisation), and the
# server is its GRANDchild through `timeout` — so killing `$!` reaps the shell
# and orphans the runtime. Eight cases of that is eight live servers competing
# for memory, and on macOS the kernel eventually SIGKILLs something: the symptom
# was `Killed: 9` on a freshly built binary in the `build` entry point, i.e. the
# leak presenting as a crash in an unrelated entry point. Matching on the exact
# `--port N` keeps this scoped to the server this function started.
reap_nrepl() {
    pkill -f "nrepl --port $1( |$)" 2>/dev/null || true
}

run_nrepl() {
    local port=$(( 19000 + (RANDOM % 900) ))
    rm -f "$WORK/.nrepl-port"
    ( cd "$WORK" && run_bounded 60 "$BIN" nrepl --port "$port" -cp src >/dev/null 2>&1 ) &
    local pid=$!
    local deadline=$((SECONDS + 30))
    while [[ ! -f "$WORK/.nrepl-port" ]] && [[ $SECONDS -lt $deadline ]]; do sleep 0.1; done
    if [[ ! -f "$WORK/.nrepl-port" ]]; then
        reap_nrepl "$port"; kill "$pid" 2>/dev/null || true
        echo "NREPL-NO-BIND"; return 0
    fi
    local out
    out=$(python3 "$ROOT/test/e2e/support/nrepl_eval.py" "$port" "$1" 2>&1 || true)
    reap_nrepl "$port"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf '%s' "$out"
}

ENTRY_POINTS=(e_flag file stdin repl nrepl build)
build_seq=0

# --- The oracle: for each program, every entry point must agree. ---
cases=0
for spec in "${PROGRAMS[@]}"; do
    name="${spec%%|*}"
    prog="${spec#*|}"
    reference=""
    reference_ep=""
    reference_raw=""
    for ep in "${ENTRY_POINTS[@]}"; do
        # An entry point that DIES is a finding, not a reason to abort: detecting
        # "this one behaves differently" is the whole job. Without this, a killed
        # child's status propagates through the assignment under `set -e` and the
        # step exits 137 with no indication of which entry point or why.
        set +e
        raw=$("run_${ep}" "$prog" 2>&1)
        st=$?
        set -e
        [[ "$st" -ne 0 ]] && raw="$raw
ENTRYPOINT-EXIT-$st"
        # Compare the marked result lines (see the header): value echoes differ
        # by entry-point contract, everything else must agree.
        got=$(printf '%s' "$raw" | grep '^RESULT ' | sed -e 's/[[:space:]]*$//' || true)
        if [[ -z "$reference_ep" ]]; then
            reference="$got"
            reference_ep="$ep"
            reference_raw="$raw"
            continue
        fi
        if [[ "$got" != "$reference" ]]; then
            echo "FAIL $name: entry points disagree" >&2
            echo "  $reference_ep -> '$reference'" >&2
            echo "  $ep -> '$got' (exit $st)" >&2
            echo "  program: $prog" >&2
            echo "  --- $ep raw output ---" >&2
            printf '%s\n' "$raw" | tail -20 | sed 's/^/  /' >&2
            exit 1
        fi
    done
    # Entry points that agree by all failing identically would pass the diff and
    # prove nothing — require the shared answer to be a real result line.
    case "$reference" in
        "RESULT "*) : ;;
        *)
            echo "  --- $reference_ep raw output ---" >&2
            printf '%s\n' "$reference_raw" | tail -20 | sed 's/^/  /' >&2
            fail "$name: every entry point produced a non-result: '$reference'" ;;
    esac
    echo "PASS $name -> $reference (${#ENTRY_POINTS[@]} entry points agree)"
    cases=$((cases + 1))
done

echo "OK — entrypoint_eval_parity ($cases programs x ${#ENTRY_POINTS[@]} entry points)"
