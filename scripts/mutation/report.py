#!/usr/bin/env python3
"""scripts/mutation/report.py — turn a mutation run's JSONL log into a report.

Reclassifies each surviving mutant against the equivalence register
(.dev/mutation_equivalent.jsonl), matching on file + op + before. An entry in
that register is excluded from the mutation score; an entry that matches no
enumerated candidate is reported as STALE and exits non-zero.

Verdicts after reclassification:
  killed      — the suite failed. The line is constrained.
  survived    — the suite passed. No test constrains the line.
  equivalent  — registered as unobservable, with a proof. Not scored.
  unviable    — did not compile. Says nothing either way.

Score = killed / (killed + survived).
"""
import argparse
import collections
import json
import sys


def load_jsonl(path, allow_missing=False):
    try:
        fh = open(path)
    except FileNotFoundError:
        if allow_missing:
            return []
        raise
    with fh:
        return [
            json.loads(line)
            for line in fh
            if line.strip() and not line.lstrip().startswith("#")
        ]


def key(row):
    return (row["file"], row["op"], row["before"])


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--stamp", required=True)
    ap.add_argument("--seed", required=True)
    ap.add_argument("--total", required=True)
    ap.add_argument("--candidates")
    ap.add_argument("--equivalent")
    args = ap.parse_args(argv)

    rows = load_jsonl(args.log)
    register = load_jsonl(args.equivalent, allow_missing=True) if args.equivalent else []
    reasons = {key(e): e.get("reason", "") for e in register}

    for r in rows:
        if r["verdict"] == "survived" and key(r) in reasons:
            r["verdict"] = "equivalent"

    stale = []
    if args.candidates and register:
        present = {key(c) for c in load_jsonl(args.candidates)}
        by_file = collections.defaultdict(set)
        for f, op, before in present:
            by_file[f].add((op, before))
        for e in register:
            f = e["file"]
            # Only a file this run actually enumerated can prove an entry stale.
            if f in by_file and (e["op"], e["before"]) not in by_file[f]:
                stale.append(e)

    killed = [r for r in rows if r["verdict"] == "killed"]
    survived = [r for r in rows if r["verdict"] == "survived"]
    equivalent = [r for r in rows if r["verdict"] == "equivalent"]
    unviable = [r for r in rows if r["verdict"] == "unviable"]
    scored = len(killed) + len(survived)
    score = (100.0 * len(killed) / scored) if scored else float("nan")

    with open(args.report, "w") as fh:
        w = fh.write
        w(f"# Mutation sweep — {args.stamp} (seed {args.seed})\n\n")
        w(f"- Candidates enumerated: {args.total}\n")
        w(f"- Mutants run: {len(rows)}\n")
        w(f"- Killed: {len(killed)}\n")
        w(f"- Survived: {len(survived)}\n")
        w(f"- Equivalent (registered, not scored): {len(equivalent)}\n")
        w(f"- Unviable (did not compile): {len(unviable)}\n")
        w(f"- **Mutation score: {score:.1f}%** (killed / (killed + survived))\n\n")

        if stale:
            w("## STALE equivalence entries\n\n")
            w("These are registered as equivalent but match no enumerated candidate — "
              "the line moved or changed, and the proof no longer covers it.\n\n")
            for e in stale:
                w(f"- `{e['file']}` {e['op']}: `{e['before']}`\n")
            w("\n")

        if survived:
            w("## Survivors — each is a line no test constrains\n\n")
            w("| file | line | operator | change |\n|---|---:|---|---|\n")
            for r in sorted(survived, key=lambda r: (r["file"], r["line"])):
                before = r["before"].replace("|", "\\|")
                after = r["after"].replace("|", "\\|")
                w(f"| `{r['file']}` | {r['line']} | {r['op']} | `{before}` -> `{after}` |\n")
            w("\n")
            by_file = collections.Counter(r["file"] for r in survived)
            w("### Survivors per file\n\n")
            for f, c in by_file.most_common():
                w(f"- `{f}`: {c}\n")
            w("\n")
        else:
            w("No unexplained survivors in this sample.\n\n")

        if equivalent:
            w("## Equivalent — registered as unobservable\n\n")
            for r in sorted(equivalent, key=lambda r: (r["file"], r["line"])):
                w(f"- `{r['file']}:{r['line']}` {r['op']} — {reasons[key(r)]}\n")
            w("\n")

    print(f"mutation: score {score:.1f}% — report at {args.report}")
    if equivalent:
        print(f"mutation: {len(equivalent)} survivor(s) excluded as registered-equivalent")
    if stale:
        print(f"mutation: {len(stale)} STALE equivalence entr(ies) — see the report", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
