#!/usr/bin/env python3
"""Render a benchmark Suite as Markdown tables, one renderer, one job (SRP).

The bench/README.md tables are GENERATED, never hand-maintained (v0's
hand-curated table drifted from meta.yaml, see private/notes/v0-bench-survey.md).
This writes ONLY into bench/README.md, never the repository-root README.md.

The vocabulary, which runtimes exist, what they are called, what order they go
in, which workloads are cross-language-comparable, milliseconds-to-microseconds
lives in `bench_domain.py`, not here. This file knows Markdown and nothing
else; `gen_charts.py` knows SVG and nothing else. Both read the same Suite, so
a table and a chart can never disagree about what was measured.

Usage:
    yq -o=json bench/cross-lang-latest.yaml | python3 bench/gen_cross_table.py
    # or
    python3 bench/gen_cross_table.py bench/cross-lang-latest.json

Emits a Markdown fragment on stdout: a Cold table (startup included) and, when
the datum carries warm data (compare_langs.sh --both), Warm and Startup tables
all honestly, since no single number tells the whole story. Pipe through
`md-table-align` (or let the commit hook align) before committing.
"""
import sys

import bench_domain as dom


def render_table(suite, mode):
    """Suite × mode -> Markdown table lines."""
    cols = suite.runtimes(mode)
    lines = ["| Benchmark | " + " | ".join(dom.display(r) for r in cols) + " |",
             "|" + "---|" * (len(cols) + 1)]
    for w in suite.workloads(mode):
        vals = [suite.fmt(suite.micros(mode, w, r)) for r in cols]
        lines.append(f"| {w} | " + " | ".join(vals) + " |")
    return lines


def render_startup(suite):
    """One-row table of per-runtime process-spawn + init time, the fixed
    overhead the warm table subtracts out."""
    order = (dom.WASM_FFI_ORDER if suite.kind == dom.WASM_FFI
             else dom.CROSS_LANG_ORDER)
    cols = [r for r in order if r in suite.startup]
    if not cols:
        return []
    return [f"| Startup ({suite.unit}) | " + " | ".join(dom.display(r) for r in cols) + " |",
            "|" + "---|" * (len(cols) + 1),
            "| process spawn + init | "
            + " | ".join(suite.fmt(suite.startup[r]) for r in cols) + " |"]


def main():
    suite = dom.load(sys.argv[1:], sys.stdin)
    if not suite.has(dom.COLD):
        sys.exit("no cw cold data in yaml, nothing to table")

    out = [suite.conditions(), "", suite.caveat(), ""]
    q = suite.quality(dom.COLD)
    if q:
        out += [q, ""]
    out += [
           f"#### {suite.mode_label(dom.COLD)} ({suite.unit}, lower is better)", "",
           "\n".join(render_table(suite, dom.COLD))]

    # Warm / startup tables appear ONLY when the datum carries that data
    # (compare_langs.sh --both). The default --cold run omits them by design.
    if suite.has(dom.WARM):
        out += ["", f"#### {suite.mode_label(dom.WARM)} ({suite.unit}, lower is better)", "",
                "\n".join(render_table(suite, dom.WARM))]

    startup_lines = render_startup(suite)
    if startup_lines:
        out += ["", f"#### Startup, process spawn + runtime init ({suite.unit}, lower is better)",
                "", "\n".join(startup_lines)]

    if suite.has(dom.WARM):
        out += ["", "_Warm = cold − startup; digits below startup-measurement "
                "noise are indicative._"]

    print("\n".join(out))


if __name__ == "__main__":
    main()
