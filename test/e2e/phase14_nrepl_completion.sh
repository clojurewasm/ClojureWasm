#!/usr/bin/env bash
# test/e2e/phase14_nrepl_completion.sh
#
# CIDER completion parity (user-directed 2026-07-15, e2e-first): replay
# the mainline-captured fixtures (test/e2e/fixtures/completion/ — see
# scripts/completion_oracle.clj) against cljw's nREPL `completions` op,
# with NO JVM needed at gate time. Per-group policy:
#   - exact groups: cljw's normalized reply == the mainline fixture
#     (vars incl. dash-fuzzy `ma-i` + `tru` special-form/literal, user
#     ns, stdlib ns/alias, negatives).
#   - subset groups: every cljw candidate must exist in the fixture AND
#     a curated MUST list must be present — where mainline's extras are
#     its classpath leak (classes — AD-054), its environment-interned
#     keywords, vars cljw does not carry (definline/defstruct/…, the
#     D-562 parity-inventory arc), or Character/TYPE
#     (designed skip + D-561).
#   - every reply must be by-name sorted (the built-in's sort-by).
#
# Refresh the fixtures with `bb scripts/completion_oracle.clj
# --capture` (spawns a real JVM nREPL + cider-nrepl); the parity gap
# audit is `--diff`.

set -euo pipefail
cd "$(dirname "$0")/../.."

bb scripts/completion_oracle.clj --regression

echo "ALL PASS phase14_nrepl_completion"
