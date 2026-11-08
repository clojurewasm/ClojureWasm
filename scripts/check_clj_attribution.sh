#!/usr/bin/env bash
# scripts/check_clj_attribution.sh
#
# PreToolUse hook on Bash that physically blocks `git commit` when any
# Clojure-namespace source file in the working tree lacks the EPL-2.0
# attribution header. Enforces memory 20260909234633-115f1e0c (clj_attribution) (D-366):
# every `src/lang/clj/clojure/**/*.clj` MUST carry
# `SPDX-License-Identifier: EPL-2.0` (both header variants ① upstream-text
# banner and ② independent-reimpl carry this single line, so one check
# guarantees both).
#
# Scope: src/lang/clj/clojure/ only. The `src/lang/clj/cljw/` namespaces
# are ClojureWasm-original and intentionally out of scope (no upstream
# lineage). `.zig` is clean-room; the import-relationship legal/NOTICE covers
# the tree-level attribution.
#
# Why a working-tree (not staged-diff) check: a new clojure ns can be
# added untracked and committed in one step; scanning the working tree
# with `find` catches both tracked and untracked `.clj` so a header-less
# file can never slip in. This is the deterministic enforcement layer
# behind the probabilistic CLAUDE.md / clj_attribution.md rule.
#
# Safe no-op for any non-`git commit` Bash invocation.

set -euo pipefail

source "$(dirname "$0")/hook_lib.sh"

# Two entry points. As a PreToolUse hook it reads the command from stdin and
# only acts on `git commit`. With `--gate` it runs the same checks directly, so
# CI — which does not run hooks — catches the same defects. A hook nothing else
# re-runs only protects the machine it is installed on.
if [[ "${1:-}" == "--gate" ]]; then
  cd "$(dirname "$0")/.."
else
  hook_read_command
  hook_is_git_commit || exit 0
  hook_cd_project_root
fi

CLJ_DIR="src/lang/clj/clojure"
[[ -d "$CLJ_DIR" ]] || exit 0

# Working-tree sweep: every .clj under clojure/ (tracked or not). `find`
# avoids the `git ls-files 'clojure/**/*.clj'` pitfall — that glob misses
# the top-level clojure/*.clj files (pathspec `**` does not match a single
# path segment), so it would silently skip core.clj/set.clj/edn.clj/etc.
missing=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! grep -q 'SPDX-License-Identifier: EPL-2.0' "$f"; then
    missing+=("$f")
  fi
done < <(find "$CLJ_DIR" -type f -name '*.clj' | sort)

if [[ ${#missing[@]} -eq 0 ]]; then
  # Second invariant: legal/NOTICE lists exactly the files that reproduce
  # upstream source text. The SPDX check above cannot see this — both header
  # variants carry the same SPDX line — so the variant-① set drifted from the
  # notice for six files before anyone counted (2026-08-04: the notice said
  # "Three files" while nine carried the banner). A notice that under-reports
  # attribution is a legal-accuracy defect in a public EPL-2.0 project, and it
  # is exactly the kind of claim only an executed check keeps honest.
  banner_files="$(grep -rl 'Copyright (c) Rich Hickey\|Copyright (c) Stuart Sierra\|by Jason Sankey' "$CLJ_DIR" --include='*.clj' 2>/dev/null | sort || true)"
  notice_files="$(grep -oE 'src/lang/clj/clojure/[A-Za-z0-9._/-]+\.clj' legal/NOTICE 2>/dev/null | sort -u || true)"
  if [[ "$banner_files" != "$notice_files" ]]; then
    {
      echo "✗ commit blocked by scripts/check_clj_attribution.sh"
      echo
      echo "legal/NOTICE does not list exactly the files that reproduce upstream source text."
      echo "  Carrying the upstream banner but NOT in NOTICE:"
      comm -23 <(printf '%s\n' "$banner_files") <(printf '%s\n' "$notice_files") | sed 's/^/    /'
      echo "  Listed in NOTICE but NOT carrying the banner:"
      comm -13 <(printf '%s\n' "$banner_files") <(printf '%s\n' "$notice_files") | sed 's/^/    /'
      echo
      echo "A file reproducing upstream text must appear in legal/NOTICE, and the count"
      echo "sentence at the top must match. See memory 20260909234633-115f1e0c (clj_attribution)."
    } >&2
    exit 2
  fi
  [[ "${1:-}" == "--gate" ]] && echo "    clj_attribution: $(find "$CLJ_DIR" -name '*.clj' | wc -l | tr -d ' ') file(s) carry SPDX; NOTICE lists exactly the $(printf '%s\n' "$banner_files" | wc -l | tr -d ' ') reproducing upstream text"
  exit 0
fi

cat >&2 <<'EOF'
✗ commit blocked by scripts/check_clj_attribution.sh

One or more Clojure-namespace source files under src/lang/clj/clojure/
are missing the EPL-2.0 attribution header.

Required first-line marker (both header variants carry it):
    ;; SPDX-License-Identifier: EPL-2.0

To recover, prepend the standard header from
memory 20260909234633-115f1e0c (clj_attribution) (B-1 of the D-366 work order):
  - variant ② (independent reimplementation — the common case): the
    4-line CW-copyright header citing the upstream namespace lineage.
  - variant ① (upstream source text reproduced — template.clj and
    core/protocols.clj only): the upstream EPL banner.

Files missing the header:
EOF
printf '  %s\n' "${missing[@]}" >&2

cat >&2 <<'EOF'

(Rule: memory 20260909234633-115f1e0c (clj_attribution). Discovery recipe:
  find src/lang/clj/clojure -name '*.clj' | xargs grep -L 'SPDX-License-Identifier: EPL-2.0'
Discipline source: D-366 license attribution; framework_completion.md
requires the rule + this hook to land in the same cycle as the retrofit.)
EOF

exit 2
