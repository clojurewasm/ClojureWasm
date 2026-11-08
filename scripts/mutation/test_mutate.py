#!/usr/bin/env python3
"""Regression tests for mutation identity and legacy replay."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("mutate.py")
SPEC = importlib.util.spec_from_file_location("cljw_mutate", MODULE_PATH)
mutate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mutate)


class MutationIdentityTest(unittest.TestCase):
    SOURCE = """fn pinned(x: i32) i32 {
    return x + 1;
}
"""

    def candidates(self, directory: Path, name: str, source: str):
        path = directory / name
        path.write_text(source, encoding="utf-8")
        return mutate.enumerate_mutants(str(path))

    def test_id_survives_line_and_file_move(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.candidates(root, "before.zig", self.SOURCE)
            moved = self.candidates(root, "after.zig", "// inserted\n\n" + self.SOURCE)
            self.assertEqual([m["id"] for m in original], [m["id"] for m in moved])
            self.assertEqual("pinned", original[0]["scope"])

    def test_same_mutation_in_different_functions_has_distinct_id(self):
        source = self.SOURCE + self.SOURCE.replace("pinned", "other")
        with tempfile.TemporaryDirectory() as tmp:
            rows = self.candidates(Path(tmp), "same.zig", source)
        add_rows = [row for row in rows if row["op"] == "const_bump_in_arith"]
        self.assertEqual(2, len(add_rows))
        self.assertEqual(2, len({row["id"] for row in add_rows}))

    def test_legacy_alias_attaches_by_stable_locator(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = self.candidates(root, "moved.zig", self.SOURCE)
            target = next(row for row in rows if row["op"] == "const_bump_in_arith")
            alias_path = root / "aliases.jsonl"
            alias = {field: target[field] for field in mutate.ALIAS_FIELDS}
            alias["id"] = "legacy123456"
            alias_path.write_text(json.dumps(alias) + "\n", encoding="utf-8")
            mutate.attach_aliases(rows, str(alias_path))
            self.assertEqual(["legacy123456"], target["aliases"])


if __name__ == "__main__":
    unittest.main()
