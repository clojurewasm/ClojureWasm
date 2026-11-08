#!/usr/bin/env bash
#
# check_test_reach.sh — flag .zig files that ship `test {...}`
# blocks but are not reachable from `src/main.zig` via the
# `@import` graph.
#
# Background: Zig 0.16 analyses top-level decls lazily. A file
# imported only via `pub const X = @import("...")` (with X
# unreferenced) is NOT pulled into the test set, and its
# `test {}` blocks silently never run. Worse, latent compile
# errors inside the file go undetected.
#
# See memory 20260909235200-1f86720b (zig_tips) "Test discovery via @import".
#
# Usage:
#   bash scripts/check_test_reach.sh            # informational
#   bash scripts/check_test_reach.sh --gate     # exit 1 if any
#                                               # file is unreachable
#
# Exit codes:
#   0   no unreachable test files
#   1   --gate mode: at least one unreachable test file (gate fail)
#   2   internal script error
set -euo pipefail

cd "$(dirname "$0")/.."

mode="${1:-informational}"

# Test roots — every `addTest(.{ .root_module = X })` site in
# `build.zig` introduces an independent test executable whose
# analysis set starts from a different `root_source_file`. A
# `.zig` file with a `test {}` block runs ONLY if it's reachable
# from the exe whose test runner it's part of. Reaching from
# root #1 doesn't help if the file belongs to root #2.
#
# cw v1 today (Phase 6) has a single `addTest()`. The list below
# is open for extension: when a second test exe lands (spec
# runner, fuzz harness, etc.), append its root_source_file path
# here so the union BFS stays sound. zwasm v2's reciprocal
# observation surfaced this multi-test-root blind spot —
# auto-parsing `build.zig` is the future improvement, but a
# manual list is enough at cw v1's current scale and stays
# obvious in `git diff`.
test_roots=("src/main.zig")

for root_file in "${test_roots[@]}"; do
    if [[ ! -f "$root_file" ]]; then
        echo "check_test_reach: configured test root $root_file not found" >&2
        exit 2
    fi
done

# Sanity check: warn loudly if `build.zig` carries more addTest
# sites than this script knows about. Cheap insurance against the
# script silently degrading as the test infrastructure grows.
build_test_count="$(grep -cE 'addTest\(' build.zig 2>/dev/null || echo 0)"
if [[ "$build_test_count" -gt "${#test_roots[@]}" ]]; then
    cat >&2 <<EOF
check_test_reach: WARNING — build.zig has $build_test_count addTest() sites
but this script only walks ${#test_roots[@]} root(s):
  ${test_roots[*]}

A new test exe was added without updating this script. Append its
root_source_file path to the test_roots array near the top of
$(basename "$0") so the union BFS covers it. Until then a file
reachable only from the new exe's root counts as unreachable here.
EOF
fi

# Collect all .zig files under src/ that contain at least one
# `^test ` block (line starts with "test " — covers both
# `test "name"` and `test {` anonymous forms).
# (portable read loop rather than `mapfile` — the latter is a bash 4+ builtin
# absent from macOS's system bash 3.2, so a bare-clone gate would fail there.)
test_files=()
while IFS= read -r _tf; do test_files+=("$_tf"); done \
    < <(grep -rl '^test ' src/ --include='*.zig' | sort -u)

# BFS the union of @import-reachable files from every configured
# test root. `reachable` records absolute paths so duplicate-path
# edges don't loop and so the union is taken implicitly.
declare -A reachable
queue=("${test_roots[@]}")
while [[ ${#queue[@]} -gt 0 ]]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    abs="$(realpath "$cur" 2>/dev/null || true)"
    [[ -z "$abs" || -n "${reachable[$abs]:-}" ]] && continue
    reachable[$abs]=1
    dir="$(dirname "$cur")"
    while read -r rel; do
        [[ -z "$rel" ]] && continue
        target="$dir/$rel"
        if [[ -f "$target" ]]; then
            queue+=("$target")
        fi
    done < <(grep -oE '@import\("[^"]+\.zig"\)' "$cur" 2>/dev/null \
             | sed -E 's/.*"([^"]+)".*/\1/' || true)
done

unreachable=()
for f in "${test_files[@]}"; do
    abs="$(realpath "$f" 2>/dev/null || true)"
    if [[ -z "${reachable[$abs]:-}" ]]; then
        unreachable+=("$f")
    fi
done

if [[ ${#unreachable[@]} -eq 0 ]]; then
    echo "check_test_reach: all $(printf '%d' "${#test_files[@]}") test-bearing .zig files reachable from ${#test_roots[@]} root(s)"
    exit 0
fi

cat <<EOF
check_test_reach: ${#unreachable[@]} test-bearing .zig file(s) NOT reachable from $root_file.

These files contain \`test {...}\` blocks that Zig 0.16's lazy
decl analysis silently skips. Add a line to the test{} aggregator
in src/main.zig:

EOF
for f in "${unreachable[@]}"; do
    n=$(grep -c '^test ' "$f")
    rel="${f#./}"
    rel_from_main="${rel#src/}"
    echo "    _ = @import(\"${rel_from_main}\");   // $n test blocks"
done
echo
echo "Background: memory 20260909235200-1f86720b (zig_tips) \"Test discovery via @import\""

if [[ "$mode" == "--gate" ]]; then
    exit 1
fi
exit 0
