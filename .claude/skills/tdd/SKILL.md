---
name: tdd
description: >
  t-wada style TDD cycle (Red-Green-Refactor) for implementing functions
  and modules. Use when user says "TDD で実装", "テスト駆動で", "write tests
  first", "Red-Green-Refactor", or asks to implement a function with tests.
  Do NOT use for adding tests to existing code without the full TDD cycle.
compatibility: Claude Code only. Requires zig build test.
metadata:
  author: clojurewasm
  version: 1.0.0
---

# TDD Skill

Implement $ARGUMENTS using the strict TDD cycle by t-wada (Takuto Wada).

## Steps

1. **Test list**: enumerate behaviors to implement as a test list
2. **Pick simplest**: choose the simplest one from the test list
3. **Red**: write a failing test. Confirm failure with `zig build test`
4. **Green**: write minimal code to pass. Fake implementation (return constant) is fine
5. **Confirm pass**: `zig build test`
6. **Refactor**: remove duplication, clean up code. Do not break tests
7. **Confirm pass**: `zig build test`
8. **Commit**: `git commit` (only when tests pass)
9. **Next**: return to test list, pick next case (go to 2)

## Key Patterns

See `references/tdd-patterns.md` for details:

- Fake It: pass first test with hardcoded constant
- Triangulate: second test forces generalization
- Obvious Implementation: implement directly when pattern is clear

## Rules

- Never add more than one test at a time
- Never write Green code without confirming Red first
- Never add tests during Refactor step
- Reference Beta code but never bring code in without tests
