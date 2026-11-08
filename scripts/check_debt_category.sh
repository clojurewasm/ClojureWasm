#!/usr/bin/env bash
# scripts/check_debt_category.sh
#
# Closed-vocabulary guard for the `category:` field of `.dev/debt.yaml`.
# The field is read as an enum (drain-by-category, easiest-first order), but
# it drifted as free text: quoted vs bare values and synonym pairs
# (structure/structural, test/tests/testing, numeric/numerics,
# perf/performance) split every grouped count. The allowed set lives in the
# ledger's own `conventions:` block, on the line starting
# "- Category vocabulary is a closed set"; this script checks that every
# `category:` value is double-quoted and drawn from that set.
#
# Informational by default (exit 0). Pass --gate to exit 1 on a violation.
set -euo pipefail
cd "$(dirname "$0")/.."

DEBT=.dev/debt.yaml
gate=0
[ "${1:-}" = "--gate" ] && gate=1

allowed_line=$(grep -m1 -E '^  - Category vocabulary is a closed set' "$DEBT" || true)
if [ -z "$allowed_line" ]; then
  echo "check_debt_category: VIOLATION -- no closed category set in $DEBT conventions." >&2
  exit 1
fi
allowed=" $(sed -E 's/.*Allowed: ([^.]*)\..*/\1/' <<<"$allowed_line") "

bad=0
while IFS= read -r line; do
  lineno=${line%%:*}
  value=$(sed -E 's/^[0-9]+:[[:space:]]*category:[[:space:]]*//' <<<"$line")
  case "$value" in
    \"*\") name=${value#\"}; name=${name%\"} ;;
    *) echo "check_debt_category: $DEBT:$lineno unquoted category: $value"; bad=$((bad + 1)); continue ;;
  esac
  case "$allowed" in
    *" $name "*) ;;
    *) echo "check_debt_category: $DEBT:$lineno category \"$name\" is not in the closed set"; bad=$((bad + 1)) ;;
  esac
done < <(grep -n -E '^[[:space:]]*category:' "$DEBT")

if [ "$bad" -gt 0 ]; then
  echo "check_debt_category: $bad violation(s). Normalize the value or add it to the conventions closed set." >&2
  [ "$gate" -eq 1 ] && exit 1
fi
exit 0
