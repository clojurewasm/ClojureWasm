#!/usr/bin/env python3
"""Generate the cross-language benchmark Markdown table from compare_langs.sh's
--yaml output. The README cross-lang table is GENERATED, never hand-maintained
(v0's hand-curated table drifted from meta.yaml — see private/notes/v0-bench-survey.md).

Usage:
    yq -o=json bench/cross-lang-latest.yaml | python3 bench/gen_cross_table.py
    # or
    python3 bench/gen_cross_table.py bench/cross-lang-latest.json

Emits a Markdown fragment (table + env caption + win-rate summary) on stdout.
Pipe through `md-table-align` (or let the commit hook align) before committing.
"""
import json
import sys

# Column order: CW first (the reference the table showcases), then the dynamic
# languages CW competes with, then the AOT-native baselines last. A lang absent
# from the data (e.g. tinygo/zig not built on this host) is dropped entirely.
LANG_ORDER = ["cw", "python", "ruby", "node", "java", "bb", "tgo", "zig", "c"]
DISPLAY = {
    "c": "C", "zig": "Zig", "java": "Java", "tgo": "TinyGo", "cw": "CW",
    "node": "Node", "bb": "BB", "ruby": "Ruby", "python": "Python",
}
# compare_langs.sh writes either short (py/rb/js) or long (python/ruby/node)
# lang keys depending on version; normalise both to our canonical keys.
ALIAS = {"py": "python", "rb": "ruby", "js": "node", "clojurewasm": "cw"}
# Dynamic langs cw is meant to beat — the win-rate summary compares against these.
RIVALS = ["python", "ruby", "node", "java", "bb"]


def norm(lang):
    return ALIAS.get(lang, lang)


def main():
    raw = (open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read())
    data = json.loads(raw)
    benches = data.get("benchmarks", {})
    env = data.get("env", {})
    date = data.get("date", "")

    # Collect, per bench, the cold ms per normalised lang (skip benches with no cw).
    rows = {}
    present = set()
    for name, modes in benches.items():
        cold = (modes or {}).get("cold") or {}
        cells = {}
        for lang, ms in cold.items():
            nl = norm(lang)
            cells[nl] = ms
            present.add(nl)
        if "cw" in cells:
            rows[name] = cells

    cols = [l for l in LANG_ORDER if l in present]
    if "cw" not in cols:
        sys.exit("no cw data in yaml — nothing to table")

    out = []
    header = "| Benchmark | " + " | ".join(DISPLAY[l] for l in cols) + " |"
    delim = "|" + "---|" * (len(cols) + 1)
    out.append(header)
    out.append(delim)
    for name, cells in rows.items():
        vals = []
        for l in cols:
            v = cells.get(l)
            vals.append(f"{float(v):g}" if v is not None else "—")
        out.append(f"| {name} | " + " | ".join(vals) + " |")

    # Win-rate summary: count benches where cw cold < rival cold (lower = faster).
    summary = []
    for rv in RIVALS:
        if rv not in present:
            continue
        wins = total = 0
        for cells in rows.values():
            if rv in cells and "cw" in cells:
                total += 1
                if float(cells["cw"]) < float(cells[rv]):
                    wins += 1
        if total:
            summary.append(f"vs {DISPLAY[rv]}: {wins}/{total}")

    cap = (f"_Cold-start wall-clock, ms (lower is better). "
           f"{env.get('cpu', '?')}, {env.get('os', '?')}, "
           f"hyperfine runs={env.get('runs', '?')}/warmup={env.get('warmup', '?')}, {date}._")
    print("\n".join(out))
    print()
    print(cap)
    if summary:
        print()
        print("**CW cold-start wins** — " + ", ".join(summary) + ".")


if __name__ == "__main__":
    main()
