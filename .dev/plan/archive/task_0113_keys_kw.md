# T13.8: {:keys [:a]} keyword destructuring

Phase 13c — Core.clj Expansion

## Goal

Support {:keys [:a :b]} syntax (keywords in :keys vector, in addition to symbols).

## Result

- Modified analyzer.zig analyzeMapDestructure: accept .keyword in :keys vector
- Keyword name is used as both the binding name and the lookup key
- SCI: 72/74 tests, 260 assertions (+1 from \_\_ds-h4)

## Log

- One-line fix in analyzer.zig: check sym_form.data == .keyword in addition to .symbol
- Enabled \_\_ds-h4 and its assertion in SCI test
