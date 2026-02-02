# IDE Integration Patterns (ZLS / Emacs MCP)

## File structure overview (before Read)

```
imenu-list-symbols(file_path: "src/common/builtin/registry.zig")
-> Returns all function names and line numbers -> Read only needed functions
```

## Impact analysis before refactoring

```
xref-find-references(identifier: "Value", file_path: "src/common/value.zig")
-> Returns all files/lines using Value -> Understand change scope
```

## Immediate error detection after edits

```
getDiagnostics(uri: "file:///path/to/edited.zig")
-> Detect compile errors before building
```

## Notes

- `xref-find-apropos` and `treesit-info` are not functional for Zig (tags / tree-sitter not configured)
- `xref-find-references` may return many results for core types (Value, etc.)
