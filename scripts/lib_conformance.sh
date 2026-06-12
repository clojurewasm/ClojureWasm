#!/usr/bin/env bash
# scripts/lib_conformance.sh — standing library-conformance harness (D-405).
#
# Measures, per real-world library, how much of its FUNCTION surface cljw
# reproduces against the `clj` oracle — the §1.5 track-1 "converging compat
# metric". Function-level triage found gaps (D-401/402/403) that load-only
# triage (verify_projects.sh) missed; this harness makes that triage a
# standing, mechanically re-checkable suite instead of an ad-hoc shell loop.
#
# Usage:
#   bash scripts/lib_conformance.sh <lib>                  # replay corpus (cljw-only)
#   bash scripts/lib_conformance.sh <lib> --oracle FILE|-  # author: diff cljw vs clj,
#                                                          #   append classified lines
#   bash scripts/lib_conformance.sh --all                  # replay every lib +
#                                                          #   regenerate COVERAGE.md
#
# Library context resolution (the classpath SSOT — no coordinate duplication):
#   - verified_projects/<lib>/ exists  → cd there for BOTH cljw and clj; each
#     reads the same deps.edn (cljw: src/app/cli.zig auto-load; clj: cwd file).
#   - test/conformance/deps/<lib>.edn exists → the lib is BUNDLED in cljw
#     (data.json/data.csv/tools.cli): cljw runs from the repo root, clj gets
#     `-Sdeps "$(cat that-file)"` so the oracle sees the real upstream lib.
#
# Corpus format (test/conformance/<lib>.txt) — a superset of the clj_corpus
# golden-pair format:
#   <expr>                       value expression, one line
#   ;;=> <output>                golden output (cljw == clj at capture time);
#                                replay ASSERTS this (drift = exit 1)
#   ;;DIFF[<tag>] <expr>         known divergence; <tag> = D-NNN | AD-NNN |
#   ;;clj=> <output>             pending. Counted in the coverage denominator,
#                                not asserted. Replay flags it FIXED? when cljw
#                                now matches the stored clj output (promote the
#                                line to a golden pair after verifying).
#   ; comment                    ignored
#
# Coverage % = golden-pass / (golden + DIFF) — rises as DIFFs are fixed or
# (after AD classification) stays an honest measure of the accepted gap.
# Every ;;DIFF line must eventually carry a D-NNN or AD-NNN tag (the
# accepted_divergences.md two-way classification; [pending] is the in-push
# transient only).
#
# Methodology (inherited from scripts/clj_diff_sweep.sh — see its header):
#   - clj runs ONCE per batch: requires prepended (no stdout line), each expr
#     try/prn-wrapped (1 output line each, errors → `<clj-error> Class`),
#     `timeout 60` + `-J-Xmx2g` (the 2026-06-12 OOM backstop). Bound every
#     seq producer with (take N …).
#   - cljw runs ONE expr at a time via STDIN program mode (`cljw -`), which
#     prints only explicit output — `-e` would echo every form's value and
#     bury the prn line. Requires are auto-detected from `dotted.ns/` prefixes.
#   - NOT in the per-commit gate: needs network (gitlibs) + the clj oracle.
#     Run on demand and at Phase boundaries, alongside verify_projects.sh.
#
# Exit: replay modes → 0 iff no golden drift; --oracle → 0 iff no new DIFF.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BIN="$ROOT/zig-out/bin/cljw"
CLJ="${CLJ:-clj}"
DIR="test/conformance"

[ -x "$BIN" ] || { echo "building cljw…" >&2; zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null; }

# ---------- lib context ----------
# Sets: CTX_DIR (cwd for cljw), CLJ_DIR (cwd for clj) and SDEPS_ARGS.
# cljw: verified_projects/<lib>/ when present (its deps.edn auto-loads), else
# the repo root (bundled ns). clj: the same deps.edn read from the same cwd —
# UNLESS test/conformance/deps/<lib>.edn exists, which then supplies the whole
# clj-side -Sdeps map (run from the repo root so no cwd deps.edn interferes).
# That override covers both cases where the shared-deps.edn trick fails:
#   - the lib is BUNDLED in cljw (data.json/data.csv/tools.cli) — clj needs
#     the real upstream coordinate;
#   - the upstream repo has NO manifest clj accepts (lein-only, e.g. potpuri)
#     — cljw resolves it (no-deps.edn → src/, ADR-0101) but clj needs the
#     same coordinate plus `:deps/manifest :deps`.
resolve_ctx() {
    local lib="$1"
    SDEPS_ARGS=()
    CTX_DIR="$ROOT"
    [ -d "verified_projects/$lib" ] && CTX_DIR="$ROOT/verified_projects/$lib"
    CLJ_DIR="$CTX_DIR"
    if [ -f "$DIR/deps/$lib.edn" ]; then
        CLJ_DIR="$ROOT"
        SDEPS_ARGS=(-Sdeps "$(cat "$DIR/deps/$lib.edn")")
    elif [ "$CTX_DIR" = "$ROOT" ]; then
        echo "unknown lib '$lib': no verified_projects/$lib/ and no $DIR/deps/$lib.edn" >&2
        return 2
    fi
}

# ---------- cljw: one expr, stdin program mode ----------
run_cljw() {
    local expr="$1" prog
    prog="$(printf '%s\n' "$expr" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9._-]*\.[a-zA-Z0-9._-]+/' \
        | sed 's:/$::' | sort -u \
        | sed "s/.*/(try (require '&) (catch Error _ nil))/")"
    printf '%s\n(prn %s)\n' "$prog" "$expr" \
        | (cd "$CTX_DIR" && timeout 20 "$BIN" - 2>&1) | head -1
}

# ---------- replay one lib's corpus; accumulates REPLAY_* globals ----------
# PROMOTE=1 (--promote): additionally REWRITE the corpus, converting every
# ;;DIFF line whose cljw output now matches the stored clj output into a
# golden pair (the FIXED? detection made mechanical). Golden pairs, comments
# and still-DIFF lines pass through unchanged.
replay_lib() {
    local lib="$1" f="$DIR/$1.txt"
    [ -f "$f" ] || { echo "no corpus: $f" >&2; return 2; }
    resolve_ctx "$lib" || return 2
    local promote_buf=""
    if [ "$PROMOTE" = 1 ]; then
        promote_buf="$(mktemp /tmp/lib_conf_promote.XXXXXX)"
    fi
    local pass=0 drift=0 diffs=0 fixed=0
    local expr="" diff_expr="" diff_tag="" line want got
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ';;=> '*)
                [ -n "$expr" ] || continue
                want="${line#';;=> '}"
                got="$(run_cljw "$expr")"
                if [ "$got" = "$want" ]; then
                    pass=$((pass + 1))
                else
                    printf 'DRIFT [%s] %s\n   want=[%s]\n    got=[%s]\n' "$lib" "$expr" "$want" "$got"
                    drift=$((drift + 1))
                fi
                [ "$PROMOTE" = 1 ] && printf '%s\n;;=> %s\n' "$expr" "$want" >> "$promote_buf"
                expr=""
                ;;
            ';;DIFF['*'] '*)
                diff_expr="${line#';;DIFF['*'] '}"
                diff_tag="${line#';;DIFF['}"
                diff_tag="${diff_tag%%']'*}"
                diffs=$((diffs + 1))
                ;;
            ';;clj=> '*)
                if [ -n "$diff_expr" ]; then
                    want="${line#';;clj=> '}"
                    got="$(run_cljw "$diff_expr")"
                    if [ "$got" = "$want" ]; then
                        if [ "$PROMOTE" = 1 ]; then
                            printf '%s\n;;=> %s\n' "$diff_expr" "$want" >> "$promote_buf"
                            printf 'PROMOTED [%s] %s ;;=> %s\n' "$lib" "$diff_expr" "$want"
                        else
                            printf 'FIXED? [%s] %s now matches clj [%s] — promote to golden pair\n' "$lib" "$diff_expr" "$want"
                        fi
                        fixed=$((fixed + 1))
                    elif [ "$PROMOTE" = 1 ]; then
                        printf ';;DIFF[%s] %s\n;;clj=> %s\n' "$diff_tag" "$diff_expr" "$want" >> "$promote_buf"
                    fi
                    diff_expr=""
                fi
                ;;
            ''|';'*)
                [ "$PROMOTE" = 1 ] && printf '%s\n' "$line" >> "$promote_buf"
                ;;
            *) expr="$line" ;;
        esac
    done < "$f"
    if [ "$PROMOTE" = 1 ]; then
        if [ "$fixed" -gt 0 ]; then
            mv "$promote_buf" "$f"
            diffs=$((diffs - fixed))
            pass=$((pass + fixed))
            echo "promoted $fixed line(s) in $f"
        else
            rm -f "$promote_buf"
        fi
    fi
    local total=$((pass + drift + diffs))
    local pct=0
    [ "$total" -gt 0 ] && pct=$(((pass * 100) / total))
    printf '%-22s %3d/%3d golden ok, %2d known-DIFF, %2d fixable → %3d%%\n' \
        "$lib" "$pass" "$((pass + drift))" "$diffs" "$fixed" "$pct"
    REPLAY_PASS=$pass REPLAY_DRIFT=$drift REPLAY_DIFFS=$diffs REPLAY_PCT=$pct
    [ "$drift" -eq 0 ]
}

# ---------- oracle mode: diff cljw vs clj, append classified lines ----------
oracle_lib() {
    local lib="$1" src="$2" f="$DIR/$1.txt"
    resolve_ctx "$lib" || return 2

    local exprs=() line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|';'*) continue ;; *) exprs+=("$line") ;; esac
    done < <([ "$src" = "-" ] && cat || cat "$src")
    local n=${#exprs[@]}
    [ "$n" -gt 0 ] || { echo "no expressions" >&2; return 2; }

    # clj batch in the lib context (same deps.edn / -Sdeps as cljw's view).
    local batch ns
    batch="$(mktemp /tmp/lib_conformance.XXXXXX.clj)"
    trap 'rm -f "$batch"' RETURN
    while IFS= read -r ns; do
        [ -n "$ns" ] && printf "(try (require '%s) (catch Throwable _ nil))\n" "$ns" >> "$batch"
    done < <(printf '%s\n' "${exprs[@]}" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9._-]*\.[a-zA-Z0-9._-]+/' \
        | sed 's:/$::' | sort -u)
    # eval-quote so a missing var is a CATCHABLE runtime error — a bare
    # (try (prn EXPR) …) cannot catch its own compile-time resolution failure,
    # and one unresolvable expr would abort the whole batch tail (every later
    # line then false-DIFFs as <clj-missing>).
    local e
    for e in "${exprs[@]}"; do
        printf '(try (prn (eval (quote %s))) (catch Throwable e (println (str "<clj-error> " (.getName (class e))))))\n' "$e" >> "$batch"
    done
    local clj_out
    clj_out="$(cd "$CLJ_DIR" && timeout 120 "$CLJ" -J-Xmx2g ${SDEPS_ARGS+"${SDEPS_ARGS[@]}"} -M "$batch" 2>/dev/null)"
    if [ -z "$clj_out" ]; then
        echo "clj batch produced NO output (classpath/manifest failure?) — re-run without 2>/dev/null:" >&2
        echo "  (cd $CLJ_DIR && $CLJ -J-Xmx2g ${SDEPS_ARGS[*]:-} -M $batch)" >&2
        return 2
    fi
    local clj_lines
    mapfile -t clj_lines <<< "$clj_out"

    mkdir -p "$DIR"
    touch "$f"
    local fails=0 appended=0 i cj cw
    for i in $(seq 0 $((n - 1))); do
        e="${exprs[$i]}"
        cj="${clj_lines[$i]:-<clj-missing>}"
        cw="$(run_cljw "$e")"
        # Dedupe: skip an expr already in the corpus (as golden or DIFF line).
        if grep -qFx -e "$e" -e ";;DIFF[pending] $e" "$f" \
           || grep -F "] $e" "$f" | grep -q '^;;DIFF\['; then
            printf 'SKIP %s (already in corpus)\n' "$e"
            continue
        fi
        if [ "$cw" = "$cj" ]; then
            printf 'OK   %s\n' "$e"
            printf '%s\n;;=> %s\n' "$e" "$cw" >> "$f"
        else
            printf 'DIFF %s\n       cljw=[%s]\n        clj=[%s]\n' "$e" "$cw" "$cj"
            printf ';;DIFF[pending] %s\n;;clj=> %s\n' "$e" "$cj" >> "$f"
            fails=$((fails + 1))
        fi
        appended=$((appended + 1))
    done
    echo "---"
    echo "$((appended - fails))/$appended new OK, $fails new DIFF → $f (classify every [pending]: fix → golden pair, or AD-NNN)"
    [ "$fails" -eq 0 ]
}

# ---------- --all: replay everything + regenerate COVERAGE.md ----------
all_libs() {
    local rows=() lib rc=0
    local f
    for f in "$DIR"/*.txt; do
        [ -f "$f" ] || continue
        lib="$(basename "$f" .txt)"
        replay_lib "$lib" || rc=1
        rows+=("| $lib | $REPLAY_PASS | $REPLAY_DIFFS | ${REPLAY_PCT}% |")
    done
    [ "${#rows[@]}" -gt 0 ] || { echo "no corpora under $DIR" >&2; return 2; }
    {
        echo "# Library conformance coverage (generated)"
        echo
        echo "> GENERATED by \`scripts/lib_conformance.sh --all\` — do not hand-edit."
        echo "> Per-lib FUNCTION-surface conformance vs the clj oracle (D-405,"
        echo "> ROADMAP §1.5 track 1). Corpus format + methodology: the script header."
        echo "> Known-DIFF lines carry D-NNN / AD-NNN tags per"
        echo "> \`.claude/rules/accepted_divergences.md\`; load-only status lives in"
        echo "> \`docs/works/ladder.md\`, load-proof projects in \`verified_projects/\`."
        echo
        echo "| lib | golden ok | known-DIFF | coverage |"
        echo "|-----|-----------|------------|----------|"
        printf '%s\n' "${rows[@]}"
    } > "$DIR/COVERAGE.md"
    command -v md-table-align >/dev/null && md-table-align "$DIR/COVERAGE.md" >/dev/null
    echo "--- wrote $DIR/COVERAGE.md"
    return "$rc"
}

# ---------- arg parsing ----------
PROMOTE=0
case "${1:-}" in
    --all) all_libs ;;
    '') echo "usage: lib_conformance.sh <lib> [--oracle FILE|-] [--promote] | --all" >&2; exit 2 ;;
    *)
        lib="$1"; shift
        case "${1:-}" in
            --oracle) oracle_lib "$lib" "${2:--}" ;;
            --promote) PROMOTE=1; replay_lib "$lib" ;;
            *) replay_lib "$lib" ;;
        esac
        ;;
esac
