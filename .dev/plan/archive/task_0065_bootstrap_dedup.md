# T8.R2: bootstrap.zig evalString/evalStringVM Deduplication

## Goal

Extract common Reader/Analyzer/macro-env setup from `evalString()` and
`evalStringVM()` into shared helper functions, reducing duplication.

## Extracted Helpers

| Function            | Purpose                                  |
| ------------------- | ---------------------------------------- |
| `readForms()`       | Parse source string into top-level forms |
| `setupMacroEnv()`   | Save + set macro_eval_env and realize_fn |
| `restoreMacroEnv()` | Restore previous macro env state         |
| `analyzeForm()`     | Analyze single form with macro expansion |

## Changes

- `evalString()`: Uses shared helpers, same behavior
- `evalStringVM()`: Uses shared helpers, same behavior
- `MacroEnvState` struct: Captures previous env/realize for defer restore

## Verification

- `zig build test` — all green
- CLI: `(+ 1 2 3)` => 6, `(apply + [1 2 3])` => 6

## Log

1. Verified green baseline (post T8.R1)
2. Extracted `readForms`, `setupMacroEnv`/`restoreMacroEnv`, `analyzeForm`
3. Rewrote `evalString` and `evalStringVM` to use shared helpers
4. All tests green, CLI verified
