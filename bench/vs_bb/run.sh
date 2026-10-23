#!/usr/bin/env bash
# bench/vs_bb/run.sh: cljw vs babashka vs JVM Clojure on the same sources.
#
# Kanban 20261022012233-420c9fea (CLJW-BENCH-VS-BB), step 0 of decision
# 20261022012219-31249feb: every perf step toward "cljw faster than bb" is
# judged by this table.
#
# Every workload in workloads/*.clj runs >= 300 ms on bb (so startup does not
# hide the gap, which it did in bench/benchmarks/*: 28-190 ms totals against
# 23-27 ms startup), prints `RESULT <value>` (checked equal across runtimes)
# and `INPROC_MS <ms>` (time measured INSIDE the script, startup and load
# excluded). The runner reports, per runtime:
#   startup   min wall of `-e nil`
#   wall      min wall of the whole process
#   inproc    min of INPROC_MS
#   rss       peak RSS (GNU time only)
#   instr     user-space instructions (perf stat, only with --perf and a usable perf)
# and the ratios cljw/bb and cljw/JVM on inproc (the headline) and on wall.
# Min-of-N by default; with hyperfine installed the wall column comes from
# `hyperfine --runs N` (its min) instead.
#
# Release-only measurement (rule perf_measure_release, memory
# 20260909234455-390c5332): the default cljw is a ReleaseSafe -Dwasm build
# into a SEPARATE prefix, never the Debug zig-out/bin/cljw.
#
# Usage:
#   bash bench/vs_bb/run.sh                       # build ReleaseSafe, 3 runs, all runtimes
#   bash bench/vs_bb/run.sh --cljw /path/cljw     # time a given binary (no build)
#   bash bench/vs_bb/run.sh -n 5 --only fib_recursive,reduce_map
#   bash bench/vs_bb/run.sh --no-jvm --perf --probe
#   bash bench/vs_bb/run.sh --no-history          # print only, no YAML row
#   CLJW_BENCH_JVM_CP=a.jar:b.jar bash bench/vs_bb/run.sh   # JVM column without the clojure CLI
#
# Output: the table on stdout, and one YAML row appended to
# bench/vs_bb/history.yaml (override with --history FILE). Exit status is 0
# unless the runner itself breaks; a slow or mismatching workload is REPORTED,
# never fatal (the CI job is non-blocking by design).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

N=3
CLJW=""
ONLY=""
WANT_JVM=1
WANT_PERF=0
WANT_PROBE=0
HISTORY="$HERE/history.yaml"
MODE="${CLJW_BENCH_MODE:-ReleaseSafe}"
CLJ_VERSION="1.12.4"
JSON_VERSION="2.5.1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--runs) N="$2"; shift 2 ;;
        --cljw) CLJW="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --no-jvm) WANT_JVM=0; shift ;;
        --perf) WANT_PERF=1; shift ;;
        --probe) WANT_PROBE=1; shift ;;
        --history) HISTORY="$2"; shift 2 ;;
        --no-history) HISTORY=""; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- binaries
if [[ -z "$CLJW" ]]; then
    PREFIX="${TMPDIR:-/tmp}/cljw-bench-vs-bb"
    echo "[vs_bb] building cljw $MODE -Dwasm into $PREFIX" >&2
    # shellcheck source=/dev/null
    source "$ROOT/scripts/lib_build_lock.sh"
    ( cd "$ROOT" && with_build_lock zig build -Dwasm -Doptimize="$MODE" -p "$PREFIX" ) >&2 \
        || { echo "run.sh: cljw build failed" >&2; exit 1; }
    CLJW="$PREFIX/bin/cljw"
fi
[[ -x "$CLJW" ]] || { echo "run.sh: no cljw binary at $CLJW" >&2; exit 1; }

RUNTIMES=(cljw)
command -v bb >/dev/null 2>&1 && RUNTIMES+=(bb) || echo "[vs_bb] bb not found: cljw/bb column empty" >&2

JVM_CP=""
if [[ "$WANT_JVM" == 1 && -n "${CLJW_BENCH_JVM_CP:-}" ]] && command -v java >/dev/null 2>&1; then
    # CI path: a classpath of Maven Central jars, no clojure CLI needed.
    JVM_CP="$CLJW_BENCH_JVM_CP"; RUNTIMES+=(jvm)
elif [[ "$WANT_JVM" == 1 ]] && command -v clojure >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    JVM_CP="$(clojure -Spath -Sdeps "{:deps {org.clojure/clojure {:mvn/version \"$CLJ_VERSION\"} org.clojure/data.json {:mvn/version \"$JSON_VERSION\"}}}" 2>/dev/null || true)"
    [[ -n "$JVM_CP" ]] && RUNTIMES+=(jvm) || echo "[vs_bb] clojure -Spath failed: no JVM column" >&2
fi

# GNU time gives peak RSS; BSD/macOS time has a different flag set, skip there.
GTIME=""
if [[ -x /usr/bin/time ]] && /usr/bin/time -f '%M' -o /dev/null true 2>/dev/null; then GTIME=/usr/bin/time; fi
HYPERFINE=""
command -v hyperfine >/dev/null 2>&1 && HYPERFINE=hyperfine
PERF=""
if [[ "$WANT_PERF" == 1 ]] && command -v perf >/dev/null 2>&1 \
   && perf stat -x, -e instructions:u -o /dev/null true 2>/dev/null; then PERF=perf; fi
[[ "$WANT_PERF" == 1 && -z "$PERF" ]] && echo "[vs_bb] perf stat unusable here (perf_event_paranoid?): no instr column" >&2

cmd_for() { # runtime file-or-empty -> argv on stdout (one string)
    local rt="$1" f="$2"
    case "$rt" in
        cljw) [[ -n "$f" ]] && echo "$CLJW $f" || echo "$CLJW -e nil" ;;
        bb)   [[ -n "$f" ]] && echo "bb $f" || echo "bb -e nil" ;;
        jvm)  [[ -n "$f" ]] && echo "java -cp $JVM_CP clojure.main $f" || echo "java -cp $JVM_CP clojure.main -e nil" ;;
    esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vs_bb.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

now_ns() { date +%s%N; }

# measure RT FILE -> sets M_WALL M_INPROC M_RESULT M_RSS M_INSTR M_ERR (min over N)
measure() {
    local rt="$1" f="$2" cmd i t0 t1 w ip rss
    cmd="$(cmd_for "$rt" "$f")"
    M_WALL=""; M_INPROC=""; M_RESULT=""; M_RSS=""; M_INSTR=""; M_ERR=""
    # one warmup run (page cache, JIT-free but disk-warm), not counted
    $cmd >/dev/null 2>&1
    for ((i = 0; i < N; i++)); do
        t0=$(now_ns)
        if [[ -n "$GTIME" ]]; then
            $GTIME -f '%M' -o "$TMP/rss" $cmd >"$TMP/out" 2>"$TMP/err"
        else
            $cmd >"$TMP/out" 2>"$TMP/err"
        fi
        local rc=$?
        t1=$(now_ns)
        if [[ $rc -ne 0 ]]; then
            M_ERR="ERR$rc"; head -c 400 "$TMP/err" >"$TMP/lasterr.$rt"; return
        fi
        w=$(( (t1 - t0) / 1000000 ))
        [[ -z "$M_WALL" || $w -lt $M_WALL ]] && M_WALL=$w
        ip="$(awk '/^INPROC_MS /{print $2}' "$TMP/out")"
        [[ -n "$ip" ]] && { [[ -z "$M_INPROC" || $ip -lt $M_INPROC ]] && M_INPROC=$ip; }
        M_RESULT="$(awk '/^RESULT /{print $2}' "$TMP/out")"
        if [[ -n "$GTIME" ]]; then
            rss="$(tail -1 "$TMP/rss")"
            [[ -z "$M_RSS" || $rss -gt $M_RSS ]] && M_RSS=$rss
        fi
    done
    if [[ -n "$HYPERFINE" ]]; then
        if $HYPERFINE -N --runs "$N" --warmup 0 --export-json "$TMP/hf.json" "$cmd" >/dev/null 2>&1; then
            local hmin
            hmin="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["results"][0]["min"]*1000))' "$TMP/hf.json" 2>/dev/null || true)"
            [[ -n "$hmin" ]] && M_WALL="$hmin"
        fi
    fi
    if [[ -n "$PERF" ]]; then
        perf stat -x, -e instructions:u -o "$TMP/perf" $cmd >/dev/null 2>&1 \
            && M_INSTR="$(awk -F, '/instructions/{print $1; exit}' "$TMP/perf")"
    fi
}

ratio() { # a b -> a/b with 2 decimals, or "-"
    [[ -n "$1" && -n "$2" && "$2" != 0 ]] && awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a/b}' || echo "-"
}

version_of() {
    case "$1" in
        cljw) "$CLJW" --version 2>&1 | sed -n 1p ;;
        bb) bb --version 2>&1 | sed -n 1p ;;
        jvm) echo "clojure $CLJ_VERSION on $(java -version 2>&1 | sed -n 1p)" ;;
    esac
}

# ---------------------------------------------------------------- workloads
WORKLOADS=()
for f in "$HERE"/workloads/*.clj; do
    name="$(basename "$f" .clj)"
    if [[ -n "$ONLY" ]] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
    WORKLOADS+=("$name")
done

declare -A WALL INPROC RES RSS INSTR ERR STARTUP STARTUP_RSS
for rt in "${RUNTIMES[@]}"; do
    measure "$rt" ""
    STARTUP[$rt]="${M_WALL:-$M_ERR}"; STARTUP_RSS[$rt]="$M_RSS"
done

for name in "${WORKLOADS[@]}"; do
    f="$HERE/workloads/$name.clj"
    for rt in "${RUNTIMES[@]}"; do
        echo "[vs_bb] $name on $rt" >&2
        measure "$rt" "$f"
        WALL[$name.$rt]="$M_WALL"; INPROC[$name.$rt]="$M_INPROC"; RES[$name.$rt]="$M_RESULT"
        RSS[$name.$rt]="$M_RSS"; INSTR[$name.$rt]="$M_INSTR"; ERR[$name.$rt]="$M_ERR"
        if [[ -n "$M_ERR" ]]; then echo "[vs_bb]   $rt failed: $(tr '\n' ' ' <"$TMP/lasterr.$rt" | head -c 200)" >&2; fi
    done
done

# ---------------------------------------------------------------- table
has() { local x; for x in "${RUNTIMES[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
cell() { local v="${ERR[$1.$2]:-}"; [[ -n "$v" ]] && echo "$v" || echo "${3:--}"; }

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
LOAD="$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load averages?: ' '{print $2}' | awk '{print $1}' | tr -d ,)"
echo
echo "cljw vs bb vs JVM  commit $COMMIT  runs=$N (min)  load=$LOAD  wall=$([[ -n "$HYPERFINE" ]] && echo hyperfine || echo min-of-N)"
for rt in "${RUNTIMES[@]}"; do printf '  %-5s %s\n' "$rt" "$(version_of "$rt")"; done
printf '  startup (-e nil) ms:'; for rt in "${RUNTIMES[@]}"; do printf '  %s %s' "$rt" "${STARTUP[$rt]}"; done
printf '   cljw/bb %s\n' "$(has bb && ratio "${STARTUP[cljw]}" "${STARTUP[bb]}" || echo -)"
[[ -n "$GTIME" ]] && { printf '  idle peak RSS MB:'; for rt in "${RUNTIMES[@]}"; do printf '  %s %s' "$rt" "$(( ${STARTUP_RSS[$rt]:-0} / 1024 ))"; done; echo; }
echo
printf '%-18s %8s %8s %8s | %8s %8s %8s | %7s %7s %7s | %6s %6s %s\n' \
    workload cljw_in bb_in jvm_in cljw_wl bb_wl jvm_wl c/bb_in c/bb_wl c/jvm_in cljwMB bbMB check
geo_bb=0; geo_bb_n=0; geo_jvm=0; geo_jvm_n=0
for name in "${WORKLOADS[@]}"; do
    rb="-"; rj="-"; rw="-"
    has bb && rb="$(ratio "${INPROC[$name.cljw]}" "${INPROC[$name.bb]}")" && rw="$(ratio "${WALL[$name.cljw]}" "${WALL[$name.bb]}")"
    has jvm && rj="$(ratio "${INPROC[$name.cljw]}" "${INPROC[$name.jvm]}")"
    [[ "$rb" != "-" ]] && { geo_bb=$(awk -v g="$geo_bb" -v r="$rb" 'BEGIN{print g+log(r)}'); geo_bb_n=$((geo_bb_n+1)); }
    [[ "$rj" != "-" ]] && { geo_jvm=$(awk -v g="$geo_jvm" -v r="$rj" 'BEGIN{print g+log(r)}'); geo_jvm_n=$((geo_jvm_n+1)); }
    check=ok
    for rt in "${RUNTIMES[@]}"; do
        [[ -n "${ERR[$name.$rt]}" ]] && { check="$rt:${ERR[$name.$rt]}"; continue; }
        [[ "${RES[$name.$rt]}" != "${RES[$name.cljw]}" ]] && check="MISMATCH($rt)"
    done
    printf '%-18s %8s %8s %8s | %8s %8s %8s | %7s %7s %7s | %6s %6s %s\n' "$name" \
        "$(cell "$name" cljw "${INPROC[$name.cljw]}")" "$(cell "$name" bb "${INPROC[$name.bb]:-}")" "$(cell "$name" jvm "${INPROC[$name.jvm]:-}")" \
        "${WALL[$name.cljw]:--}" "${WALL[$name.bb]:--}" "${WALL[$name.jvm]:--}" \
        "$rb" "$rw" "$rj" \
        "$(( ${RSS[$name.cljw]:-0} / 1024 ))" "$(( ${RSS[$name.bb]:-0} / 1024 ))" "$check"
    [[ -n "$PERF" ]] && printf '%-18s   instructions:u  cljw %s  bb %s  jvm %s\n' "" \
        "${INSTR[$name.cljw]:--}" "${INSTR[$name.bb]:--}" "${INSTR[$name.jvm]:--}"
done
GEO_BB="-"; GEO_JVM="-"
[[ $geo_bb_n -gt 0 ]] && GEO_BB=$(awk -v g="$geo_bb" -v n="$geo_bb_n" 'BEGIN{printf "%.2f", exp(g/n)}')
[[ $geo_jvm_n -gt 0 ]] && GEO_JVM=$(awk -v g="$geo_jvm" -v n="$geo_jvm_n" 'BEGIN{printf "%.2f", exp(g/n)}')
echo
echo "geomean in-process ratio: cljw/bb $GEO_BB   cljw/jvm $GEO_JVM   (< 1.00 means cljw is faster)"
echo "columns: *_in = ms inside the script (INPROC_MS), *_wl = process wall ms, ratios on min values"

# ---------------------------------------------------------------- probe (per-call micro cells)
if [[ "$WANT_PROBE" == 1 ]]; then
    echo
    echo "per-call probe (probe/probe2.clj, us per call, min of 7 after warmup):"
    for rt in "${RUNTIMES[@]}"; do
        printf '  %-5s ' "$rt"; $(cmd_for "$rt" "$HERE/probe/probe2.clj") 2>&1 | tail -1
    done
    echo "RSS probe (probe/heap.clj; bb uses heap_bb.clj):"
    for rt in cljw bb; do
        has "$rt" || continue
        h="$HERE/probe/heap.clj"; [[ "$rt" == bb ]] && h="$HERE/probe/heap_bb.clj"
        echo "  $rt:"; $(cmd_for "$rt" "$h") 2>&1 | sed 's/^/    /'
    done
fi

# ---------------------------------------------------------------- YAML history row
if [[ -n "$HISTORY" ]]; then
    {
        [[ -s "$HISTORY" ]] || echo "# bench/vs_bb history: one row per run of bench/vs_bb/run.sh (append-only)."
        echo "- date: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "  commit: \"$COMMIT\""
        echo "  host: \"$(uname -sm)\""
        echo "  ci: ${CI:-false}"
        echo "  load: \"$LOAD\""
        echo "  runs: $N"
        echo "  wall_source: $([[ -n "$HYPERFINE" ]] && echo hyperfine || echo min-of-n)"
        echo "  versions:"
        for rt in "${RUNTIMES[@]}"; do echo "    $rt: \"$(version_of "$rt" | tr -d '"')\""; done
        echo "  startup_ms:"
        for rt in "${RUNTIMES[@]}"; do echo "    $rt: ${STARTUP[$rt]}"; done
        echo "  geomean_inproc: {cljw_over_bb: $GEO_BB, cljw_over_jvm: $GEO_JVM}"
        echo "  workloads:"
        for name in "${WORKLOADS[@]}"; do
            echo "    $name:"
            for rt in "${RUNTIMES[@]}"; do
                if [[ -n "${ERR[$name.$rt]}" ]]; then echo "      $rt: {error: ${ERR[$name.$rt]}}"; continue; fi
                printf '      %s: {inproc_ms: %s, wall_ms: %s' "$rt" "${INPROC[$name.$rt]:-null}" "${WALL[$name.$rt]:-null}"
                [[ -n "${RSS[$name.$rt]}" ]] && printf ', rss_kb: %s' "${RSS[$name.$rt]}"
                [[ -n "${INSTR[$name.$rt]}" ]] && printf ', instructions: %s' "${INSTR[$name.$rt]}"
                echo "}"
            done
        done
    } >>"$HISTORY"
    echo "[vs_bb] appended a row to $HISTORY" >&2
fi
exit 0
