#!/usr/bin/env bash
# test/e2e/phase16_load_file_source.sh: an error in a load-file'd file renders
# the snippet of THAT file, at its current text.
#
# Two defects shared this path. The error renderer showed the MAIN script's
# line N for an error at lib.clj:N, and the source registry it should read was
# first-write-wins, so a file loaded, edited and loaded again would render
# the first version's text. The runner loads a valid lib, swaps in a version
# whose line 3 names an unresolvable symbol, and loads it again uncaught; the
# rendered snippet must show the new line 3 and nothing from the main script
# or the first version. Main carries no lib text, so a wrong-file snippet
# cannot pass by accident.
#
# Layer 2 (e2e CLI) per ADR-0021: the snippet only exists in the CLI's
# rendered stderr.

set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
printf '(def x 1)\n(def y 2)\n(def z 3)\n' > "$dir/v1.clj"
printf '(def x 1)\n(def y 2)\n(def z (no-such-fn-edited-line 1))\n' > "$dir/v2.clj"
cat > "$dir/main.clj" <<EOF
(spit "$dir/lib.clj" (slurp "$dir/v1.clj"))
(load-file "$dir/lib.clj")
(spit "$dir/lib.clj" (slurp "$dir/v2.clj"))
(load-file "$dir/lib.clj")
EOF

err="$("$BIN" "$dir/main.clj" 2>&1 >/dev/null || true)"
fail() { echo "FAIL load_file_snippet: $1" >&2; printf '%s\n' "$err" >&2; exit 1; }
grep -qF 'lib.clj:3' <<<"$err" || fail "the error is not located at lib.clj:3"
grep -qF '(def z (no-such-fn-edited-line 1))' <<<"$err" || fail "the snippet does not show the edited lib line 3"
if grep -qF '(def z 3)' <<<"$err"; then fail "the snippet shows the stale first version"; fi
if grep -qF '(load-file' <<<"$err"; then fail "the snippet shows the main script, not lib.clj"; fi
echo "PASS load_file_snippet -> lib.clj line 3, current text"
echo "ALL phase16_load_file_source PASS"
