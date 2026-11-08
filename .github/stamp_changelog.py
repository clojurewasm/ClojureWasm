#!/usr/bin/env python3
"""Stamp CHANGELOG.md's [Unreleased] section as a released version.

Usage: stamp_changelog.py VERSION [PATH]

Renames `## [Unreleased]` to `## [VERSION] - YYYY-MM-DD` and opens a fresh
empty `## [Unreleased]` above it.

Exit 0  the file was rewritten (caller should `git add` it)
Exit 1  nothing to stamp - no file, no [Unreleased] heading, or its body is
        empty. An auto-cut patch with nothing written up must not mint an
        empty version heading, so this is a normal outcome, not an error.
Exit 2  the file is malformed in a way that needs a human.
"""

import datetime
import pathlib
import re
import sys

UNRELEASED = "## [Unreleased]"
VERSION_RE = re.compile(r"^## \[")


def stamp(text: str, version: str, today: str):
    """Return the rewritten text, or None when there is nothing to stamp."""
    lines = text.split("\n")

    start = next((i for i, l in enumerate(lines) if l.strip() == UNRELEASED), None)
    if start is None:
        return None

    end = next(
        (i for i in range(start + 1, len(lines)) if VERSION_RE.match(lines[i])),
        len(lines),
    )

    body = lines[start + 1 : end]
    if not any(l.strip() for l in body):
        return None

    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()

    return "\n".join(
        lines[:start]
        + [UNRELEASED, "", f"## [{version}] - {today}", ""]
        + body
        + [""]
        + lines[end:]
    )


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    version = sys.argv[1]
    path = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "CHANGELOG.md")

    if not path.is_file():
        print(f"{path}: not found - nothing to stamp", file=sys.stderr)
        return 1

    text = path.read_text()
    # Count HEADINGS, not substring hits: an entry that quotes the literal
    # `## [Unreleased]` in its prose is ordinary changelog writing, not a
    # malformed file.
    headings = sum(1 for l in text.split("\n") if l.strip() == UNRELEASED)
    if headings > 1:
        print(f"{path}: {headings} '{UNRELEASED}' headings", file=sys.stderr)
        return 2

    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    out = stamp(text, version, today)
    if out is None:
        print(f"{path}: [Unreleased] is empty - not stamping {version}", file=sys.stderr)
        return 1

    path.write_text(out)
    print(f"{path}: stamped [Unreleased] as [{version}] - {today}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
