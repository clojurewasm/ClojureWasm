#!/usr/bin/env python3
"""One-shot migration: .dev/debt.md (bloated pipe-table) -> .dev/debt.yaml.

The Markdown table forced `md-table-align` to pad every cell to the widest
cell in its column; one Barrier cell runs to thousands of characters, so the
file ballooned to ~800 KB of mostly whitespace. YAML (consistent with
compat_tiers.yaml / placement.yaml / feature_deps.yaml) stores the same data
with zero alignment padding and is directly machine-readable.

Lossless by construction AND verified: barrier / resolution cells can contain
literal `|` (which md-table-align rendered as extra columns), so those fields
are reconstructed by REJOINING the split fragments. After parsing, every row's
non-empty source cells are compared against the parsed fields; any mismatch
aborts the migration (no silent loss).
"""
import re

SRC = ".dev/debt.md"
DST = ".dev/debt.yaml"
PH = "\x00P\x00"  # placeholder for the markdown escape \|
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")


def cells_of(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    s = s.replace(r"\|", PH)
    return [c.strip().replace(PH, "|") for c in s.split("|")]


def parse_active(cells):
    """ID|status|category|barrier|[quality_floor]|[last_reviewed]|<padding>.

    status/category are pipe-free short cells; barrier may contain literal `|`
    so it is rejoined from the middle fragments. The tail (quality_floor,
    last_reviewed) is identified from the right by content shape.
    """
    idv, status, category = cells[0], cells[1], cells[2]
    rest = [c for c in cells[3:]]
    # strip trailing empty padding cells
    while rest and rest[-1] == "":
        rest.pop()
    last_reviewed = ""
    quality_floor = ""
    if rest and DATE.match(rest[-1]):
        last_reviewed = rest.pop()
    # a trailing "quality-loop floor:" cell is the quality_floor column
    if rest and rest[-1].startswith("quality-loop floor:"):
        quality_floor = rest.pop()
    barrier = " | ".join(rest)
    return idv, status, category, barrier, quality_floor, last_reviewed


def parse_discharged(cells):
    """ID|discharged_at|resolution(may contain literal |)|<padding>."""
    idv, at = cells[0], cells[1]
    rest = [c for c in cells[2:]]
    while rest and rest[-1] == "":
        rest.pop()
    resolution = " | ".join(rest)
    return idv, at, resolution


def nonempty_seq(cells):
    return [c for c in cells if c != ""]


def verify_active(cells, parsed):
    idv, status, category, barrier, qf, lr = parsed
    rebuilt = [idv, status, category] + barrier.split(" | ")
    if qf:
        rebuilt.append(qf)
    if lr:
        rebuilt.append(lr)
    rebuilt = [c for c in rebuilt if c != ""]
    return rebuilt == nonempty_seq(cells)


def verify_discharged(cells, parsed):
    idv, at, resolution = parsed
    rebuilt = [idv, at] + resolution.split(" | ")
    rebuilt = [c for c in rebuilt if c != ""]
    return rebuilt == nonempty_seq(cells)


def yaml_block(text, indent):
    pad = " " * indent
    return "\n".join(pad + ln for ln in text.split("\n"))


def scalar(key, val, prefix):
    esc = val.replace("\\", "\\\\").replace('"', '\\"')
    return f'{prefix}{key}: "{esc}"'


def main():
    lines = open(SRC, encoding="utf-8").read().split("\n")
    section = None
    active, discharged, conventions = [], [], []
    for ln in lines:
        if ln.startswith("## Active"):
            section = "active"; continue
        if ln.startswith("## Discharged"):
            section = "discharged"; continue
        if ln.startswith("## Conventions"):
            section = "conventions"; continue
        if section == "active" and re.match(r"^\|\s*D-", ln):
            active.append(cells_of(ln))
        elif section == "discharged" and re.match(r"^\|\s*D-", ln):
            discharged.append(cells_of(ln))
        elif section == "conventions":
            conventions.append(ln)

    # parse + verify
    errors = []
    pa = []
    for c in active:
        p = parse_active(c)
        if not verify_active(c, p):
            errors.append(("active", c[0], c))
        pa.append(p)
    pd = []
    for c in discharged:
        p = parse_discharged(c)
        if not verify_discharged(c, p):
            errors.append(("discharged", c[0], c))
        pd.append(p)

    if errors:
        for kind, idv, c in errors[:10]:
            print(f"LOSSY {kind} {idv}: nonempty={nonempty_seq(c)[:4]}...")
        raise SystemExit(f"ABORT: {len(errors)} rows failed lossless reconstruction")

    out = []
    out.append("# Debt ledger (structured SSOT; replaces the former .dev/debt.md table).")
    out.append("#")
    out.append("# Row-level debt tracking. Each active entry's `barrier` is a present-tense,")
    out.append("# testable predicate; phase-boundary audit verifies per-row, not aggregate")
    out.append("# count (ROADMAP §A13). Status: now / blocked-by: <event> / Phase N target /")
    out.append("# PARTIAL ... / DISCHARGED <SHA|ADR>. `last_reviewed` is refreshed at every")
    out.append("# continue Step 0.5 debt sweep. `quality_floor` (when present) is the standing")
    out.append("# F-010 quality-loop floor anchor. Was a Markdown table; moved to YAML so")
    out.append("# md-table-align no longer pads it to ~800 KB of whitespace.")
    out.append("")
    out.append("active:")
    for idv, status, category, barrier, qf, lr in pa:
        out.append(scalar("id", idv, "  - "))
        out.append(scalar("status", status, "    "))
        out.append(scalar("category", category, "    "))
        out.append("    barrier: |-")
        out.append(yaml_block(barrier, 6))
        if qf:
            out.append("    quality_floor: |-")
            out.append(yaml_block(qf, 6))
        if lr:
            out.append(scalar("last_reviewed", lr, "    "))
    out.append("")
    out.append("discharged:")
    for idv, at, resolution in pd:
        out.append(scalar("id", idv, "  - "))
        out.append(scalar("discharged_at", at, "    "))
        out.append("    resolution: |-")
        out.append(yaml_block(resolution, 6))
    out.append("")
    conv = "\n".join(conventions).strip("\n")
    out.append("conventions: |-")
    out.append(yaml_block(conv, 2))
    out.append("")

    open(DST, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"OK lossless: active={len(pa)} discharged={len(pd)} total={len(pa)+len(pd)}")


if __name__ == "__main__":
    main()
