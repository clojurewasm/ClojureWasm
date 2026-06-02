# cljw error rendering — `CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG`

> Stable surface from v0.1.0 onward. Changes require a MAJOR
> version bump per ROADMAP §1.4 SemVer rule.

This document specifies the two env vars that govern how `cljw`
renders runtime errors. Implementation lives in
`src/app/error_render.zig`; tests at
`test/e2e/phase14_error_format.sh`.

## `CLJW_ERROR_FORMAT`

Selects the stderr render format.

| Value          | Behavior                                                                                                                                              |
|----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| unset / `text` | Human-readable carat-pointer format. Source line + arrow indicating column + kind label + message. Default for terminal use.                          |
| `edn`          | Single-line structured EDN map (see schema below). Suitable for editor / CIDER / log-aggregator integration + `cljw render-error` post-mortem decode. |
| anything else  | Falls back to `text` (typo'd values do not break user output).                                                                                        |

### EDN event schema (v0.1.0)

```clojure
{:cljw/error true
 :kind <keyword>      ; catalog error: one of :syntax_error :number_error :string_error
                      ;   :name_error :arity_error :value_error :not_implemented :type_error
                      ;   :arithmetic_error :index_error :io_error :internal_error
                      ; user (throw v):  :exception
 :phase <keyword>     ; one of: :tokenize :parse :analysis :macroexpand :eval
 :file <string>       ; source file path or synthetic label ("<-e>", "<stdin>", "<repl:N>")
 :line <int>          ; 1-based; 0 if unknown
 :column <int>        ; 1-based; 0 if unknown
 :message <string>    ; rendered message (ex-message for a thrown ex-info; the
                      ;   printed value for a non-ex-info throw)
 :data <edn>          ; (thrown ex-info only) the ex-data map; absent otherwise
}
```

- One event per error, terminated with a single newline.
- The `:cljw/error true` discriminator MUST appear first so the
  event survives stdout/stderr interleaving in mixed log output.
- Strings are EDN-escaped: `"` → `\"`, `\` → `\\`, `\n` → `\\n`.
- A user `(throw v)` renders `:kind :exception` (it raises a thrown
  Value, not a catalog error). For `(throw (ex-info msg data))`,
  `:message` is `msg` and `:data` is `data`; for any other thrown Value
  (e.g. `(throw 42)`), `:message` is the printed value and `:data` is
  absent. Any `cljw.error/*error-context*` bound via `with-context` at
  throw time merges in as top-level fields, same as the catalog path.

### Forward compatibility

- Future keys MAY be added (e.g. `:cause`, `:trace`); a reader MUST
  tolerate unknown keys.
- The 13 `:kind` values (12 catalog + `:exception`) and 5 `:phase`
  values listed above are stable from v0.1.0; new variants ride a
  MAJOR bump.
- `:file` / `:line` / `:column` carry the analyzer's known
  location; today some locations surface as `"unknown"` /
  `0` / `0` (the analyzer doesn't yet populate the field from
  the per-call source-context). Phase 14.13 v0.1.0 release
  polish closes this gap; the field shape is stable.

## `CLJW_ERROR_LOG`

When set to a filesystem path, the EDN-rendered error event is
appended to that file IN ADDITION to the stderr render. The log
file always carries the structured event regardless of
`CLJW_ERROR_FORMAT` — text-mode users still get a machine-
parseable post-mortem trail.

### Append semantics

- File is opened with `truncate=false`; existing content is
  preserved.
- Writes go at `file.length(io)` via `writePositionalAll` so
  concurrent appends from sibling processes do not truncate
  each other.
- The file is created if absent. Permission errors / disk-full
  / path-not-found surface as silently-dropped writes — the
  primary stderr render is unaffected.
- No log rotation, no size cap, no compression. Use external
  tooling (`logrotate(8)` / Vector / Fluent Bit) if needed.

### Example consumer flow

```sh
# Production process, structured logs only on disk.
CLJW_ERROR_LOG=/var/log/cljw/errors.edn cljw app.clj

# Interactive REPL with EDN events for tail-friendly tooling.
CLJW_ERROR_FORMAT=edn cljw repl

# Both: stderr is human-readable, log file collects structured events.
CLJW_ERROR_LOG=./errors.edn cljw -e '(some-form)'

# Post-mortem decode (future, D-100c row 14.11).
cljw render-error ./errors.edn
```

## Reading the env vars from inside Clojure

Not exposed today. The env vars are read once by the cljw CLI
dispatcher at startup; the format selection is process-wide. A
future `(cljw.error/get-format)` / `(cljw.error/set-format!)` API
may surface for runtime control — out of scope for v0.1.0.

## Stability lock — v0.1.0

The env var **names** (`CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG`),
the format **value set** (`text` / `edn`), the EDN event
**discriminator key** (`:cljw/error true`), and the **12 :kind
values + 5 :phase values** above are stable from v0.1.0. Changes
require a MAJOR version bump per ROADMAP §1.4.

## Cross-references

- `.dev/debt.yaml` D-066 (this surface's tracking row).
- `src/app/error_render.zig` (implementation).
- `test/e2e/phase14_error_format.sh` (7 e2e cases).
- ROADMAP §9.16 row 14.13 (v0.1.0 polish bundle).
- ROADMAP §1.4 (SemVer rule for surface stability).
