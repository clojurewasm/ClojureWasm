# T7.0: Phase 7 Planning — Robustness + nREPL

## Goal

Plan Phase 7. Three sub-phases:

- 7a: Bug fixes (F11 stack depth, F12 str buffer)
- 7b: Expanded core library + missing features
- 7c: nREPL server for editor integration

## Context

Phase 6 delivered 140 vars (was 101). Key deferred items from checklist:

- F11: TreeWalk stack depth limit (ack(3,6) segfaults)
- F12: str fixed 4KB buffer (large string ops fail)
- F1: NaN boxing (deferred — complex, Phase 9)
- F2: Real GC (deferred — not triggered)

future.md SS19 Phase 7 = nREPL + tool integration.
But F11/F12 are bugs that should be fixed first.

## Tasks

### Phase 7a: Robustness Fixes

| #   | Task                           | Notes                                                 |
| --- | ------------------------------ | ----------------------------------------------------- |
| 7.1 | TreeWalk stack depth fix (F11) | Dynamic stack or MAX_LOCALS increase; ack(3,6) test   |
| 7.2 | str dynamic buffer (F12)       | ArrayList<u8> instead of fixed 4KB; large string test |

### Phase 7b: Core Library Expansion II

| #   | Task                                            | Notes                                                  |
| --- | ----------------------------------------------- | ------------------------------------------------------ |
| 7.3 | Missing core macros: doto, as->, cond->, some-> | Threading variants + utility macros                    |
| 7.4 | Multimethod: defmulti, defmethod                | Dynamic dispatch without protocols                     |
| 7.5 | Exception handling: try/catch/throw in eval     | Currently analyzed but not fully wired in TreeWalk     |
| 7.6 | Lazy sequences: lazy-seq, lazy-cat              | Foundation for idiomatic Clojure; iterate, repeat lazy |

### Phase 7c: nREPL Server

| #   | Task                                     | Notes                                      |
| --- | ---------------------------------------- | ------------------------------------------ |
| 7.7 | bencode encoder/decoder                  | nREPL wire protocol                        |
| 7.8 | nREPL server (TCP socket)                | eval, load-file, describe, completions ops |
| 7.9 | nREPL middleware: completion, stacktrace | Editor integration quality                 |

## Log

- Phase 7 planning started
