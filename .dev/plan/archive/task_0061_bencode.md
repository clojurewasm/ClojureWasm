# T7.7: Bencode Encoder/Decoder

## Goal

Implement bencode encoding/decoding for nREPL wire protocol.
Bencode format: strings (`<len>:<data>`), integers (`i<num>e`),
lists (`l<items>e`), dicts (`d<key><val>...e`).

## Design

Reference: ClojureWasmBeta/src/nrepl/bencode.zig (306 lines)

### Components

- `BencodeValue` tagged union: string, integer, list, dict
- `decode(allocator, data)` -> { value, consumed }
- `encode(allocator, buf, value)` -> void
- Helper: dictGet, dictGetString, dictGetInt
- Helper: encodeDict (convenience)

### Location

`src/repl/bencode.zig` — under the REPL subsystem directory.

## Plan (TDD)

1. Red: encode/decode string roundtrip
2. Green: string encode + decode
3. Red: encode/decode integer
4. Green: integer encode + decode
5. Red: encode/decode list
6. Green: list encode + decode
7. Red: encode/decode dict
8. Green: dict + helpers
9. Red: nested dict roundtrip
10. Green: full implementation
11. Refactor: clean up

## Log
