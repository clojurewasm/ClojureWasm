#!/usr/bin/env bash
# check_core_surface.sh — clojure.core's extra public surface is a decision (AD-057).
#
#   bash scripts/check_core_surface.sh          # gate
#   bash scripts/check_core_surface.sh --regen  # rewrite the expected list
#
# cljw's `clojure.core` publishes 104 names JVM Clojure does not. They are not
# leaks: cljw has no Java, so where JVM Clojure exposes the `clojure.lang.*`
# INTERFACES a `deftype` implements, cljw exposes protocols and their `-name`
# methods (ADR-0007 Option beta / ADR-0059, the ClojureScript convention —
# `cljs.core/ISeq`, `cljs.core/-first`). They must be public for
# `(deftype Foo [] ISeq (-first [_] :a))` to compile.
#
# Why a gate: the 2026-08-04 audit read that surface as "internal helpers leaked
# into the public API" and drafted a cleanup that would have broken every
# `deftype` against a host interface — including
# `test/conformance/verified_projects/data.finger-tree`, which names
# Seqable/ISeq/IPersistentStack/Indexed explicitly. Nothing in the tree recorded
# the intent, so the misreading was reasonable. This file records it, and the
# gate makes the set exact: a NEW extra name is a conscious decision, and one
# that vanishes is a breaking change to a documented surface.
#
# Deliberately compares NAMES ONLY — not arities, not docstrings. It answers
# "what is in clojure.core that upstream does not have", nothing finer.
set -uo pipefail
# `sort`/`comm` collate byte-wise, so the ledger's order is the same on every
# machine and a regen under a different locale is not spurious drift.
export LC_ALL=C
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

BIN="zig-out/bin/cljw"
EXPECTED="data/core_surface_extras.txt"
UPSTREAM="data/core_surface_upstream.txt"

[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
for f in "$EXPECTED" "$UPSTREAM"; do
    [ -f "$f" ] || { echo "check_core_surface: missing $f" >&2; exit 1; }
done

TMP_CLJW="$(mktemp)"; TMP_EXTRA="$(mktemp)"; TMP_EXPECT="$(mktemp)"
trap 'rm -f "$TMP_CLJW" "$TMP_EXTRA" "$TMP_EXPECT"' EXIT

"$BIN" -e '(doseq [s (sort (map name (keys (ns-publics (quote clojure.core)))))] (println s))' 2>/dev/null \
  | grep -v '^nil$' | sort -u > "$TMP_CLJW"

if [[ ! -s "$TMP_CLJW" ]]; then
    echo "check_core_surface: cljw produced no clojure.core publics — build broken?" >&2
    exit 1
fi

grep -v '^#' "$UPSTREAM" | grep -v '^[[:space:]]*$' | sort -u > "$TMP_EXPECT"
comm -13 "$TMP_EXPECT" "$TMP_CLJW" > "$TMP_EXTRA"

if [[ "${1:-}" == "--regen" ]]; then
    header="$(grep '^#' "$EXPECTED")"
    { printf '%s\n' "$header"; cat "$TMP_EXTRA"; } > "$EXPECTED"
    echo "check_core_surface: rewrote $EXPECTED ($(grep -vc '^#' "$EXPECTED") names) — READ THE DIFF"
    exit 0
fi

grep -v '^#' "$EXPECTED" | grep -v '^[[:space:]]*$' | sort -u > "$TMP_EXPECT"

if diff -q "$TMP_EXPECT" "$TMP_EXTRA" >/dev/null 2>&1; then
    echo "    core_surface: $(wc -l < "$TMP_EXTRA" | tr -d ' ') documented extra publics in clojure.core (AD-057)"
    exit 0
fi

echo "check_core_surface: clojure.core's extra public surface changed." >&2
echo "  '<' = expected but gone (a breaking removal from a documented surface)" >&2
echo "  '>' = new and undocumented (decide, then run --regen)" >&2
echo "" >&2
diff "$TMP_EXPECT" "$TMP_EXTRA" >&2
echo "" >&2
echo "  If the new name is a protocol / protocol method the deftype surface needs," >&2
echo "  run 'bash scripts/check_core_surface.sh --regen' and say so in the commit." >&2
echo "  If it is an implementation helper, it belongs in cljw.internal or ^:private." >&2
exit 1
