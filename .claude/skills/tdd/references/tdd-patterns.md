# TDD Patterns (t-wada)

## Fake It -> Triangulate -> Obvious Implementation

### Fake It

Return a hardcoded constant to make the first test pass.
This verifies the test infrastructure works and forces you
to write the assertion first.

Example:
- Test: `expect(add(1, 2) == 3)`
- Fake: `fn add(a, b) { return 3; }`

### Triangulate

Add a second test case that cannot pass with the fake.
This forces generalization.

Example:
- Test 2: `expect(add(3, 4) == 7)`
- Now you must implement: `fn add(a, b) { return a + b; }`

### Obvious Implementation

When the pattern is clear from the start, skip Fake It
and implement directly. Use when the logic is trivial.

## Anti-patterns
- Writing multiple tests before any Green
- Refactoring while a test is Red
- Importing Beta code without writing tests first
