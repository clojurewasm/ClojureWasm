# CLI Reference

## Usage

```
cljw [options] [file.clj]
cljw -A:alias              REPL with alias
cljw -M:alias [-m ns]      Main mode
cljw -X:alias fn [:k v]    Exec mode
cljw -P                    Resolve deps only
cljw build <file> [-o out] Build standalone binary
cljw test [files...]       Run tests
```

## Modes

### REPL (default)

```bash
cljw                  # Start interactive REPL
cljw -A:dev           # REPL with :dev alias
```

### File Execution

```bash
cljw hello.clj        # Execute a Clojure file
cljw src/app/core.clj # Execute with deps.edn classpath
```

### Expression Evaluation

```bash
cljw -e '(+ 1 2)'    # Evaluate and print result
```

### Main Mode (-M)

```bash
cljw -M:run                    # Run with :run alias
cljw -M:run -m my-app.core     # Run -main in namespace
```

Applies alias, then runs `-main` function from the specified namespace.

### Exec Mode (-X)

```bash
cljw -X:build                        # Run :exec-fn from alias
cljw -X:build my.ns/task :key val    # Override function + args
```

Calls a function with a map argument. Key-value pairs from the command
line are merged with `:exec-args` from the alias.

### Test Runner

```bash
cljw test                  # Run tests from :cljw/test-paths
cljw test -A:test          # Run tests with alias paths
cljw test src/test.clj     # Run specific test file
```

Discovers test namespaces from `test/` or `:cljw/test-paths` in deps.edn.

### Build Standalone Binary

```bash
cljw build app.clj              # Build ./app binary
cljw build app.clj -o myapp     # Build with custom name
```

Produces a single self-contained binary that embeds the CW runtime,
bootstrap, and your source code. The resulting binary starts up in ~18ms.

### Dependency Resolution

```bash
cljw -P           # Clone/fetch git deps
cljw -Sforce -P   # Force re-fetch
```

## deps.edn Flags

| Flag | Description |
|------|-------------|
| `-A:alias[:alias...]` | Apply alias(es) for REPL |
| `-M:alias[:alias...]` | Apply alias(es) for main mode |
| `-X:alias[:alias...]` | Apply alias(es) for exec mode |
| `-P` | Resolve dependencies only (git clone) |
| `-m <ns>` | Namespace to run -main (with -M) |
| `-Spath` | Print load paths |
| `-Sdeps <edn>` | Extra deps (EDN map, merged with deps.edn) |
| `-Srepro` | Exclude user config |
| `-Sforce` | Ignore cache, re-fetch |
| `-Sverbose` | Debug output for dep resolution |

## Options

| Option | Description |
|--------|-------------|
| `-e <expr>` | Evaluate expression and print result |
| `--tree-walk` | Use TreeWalk interpreter instead of VM |
| `--dump-bytecode` | Dump compiled bytecode (VM only) |
| `--nrepl-server` | Start nREPL server |
| `--port=<N>` | nREPL server port (default: auto) |
| `--version` | Print version and exit |
| `-h`, `--help` | Show help |

## deps.edn Format

CW supports a subset of the Clojure CLI deps.edn format:

```clojure
{:paths ["src"]
 :deps {lib/name {:git/url "https://..."
                   :git/tag "v1.0"
                   :git/sha "abc123"}
        local/dep {:local/root "../path"}}
 :cljw/test-paths ["test"]
 :aliases {:dev {:extra-paths ["dev"]
                 :extra-deps {}}
           :build {:exec-fn my.ns/task
                   :exec-args {:key "val"}}
           :run {:main-opts ["-m" "my-app.core"]}}}
```

### Supported Dependency Coordinates

| Type | Keys | Description |
|------|------|-------------|
| Git | `:git/url`, `:git/tag`, `:git/sha` | Git repository |
| Local | `:local/root` | Local filesystem path |

### CW-Specific Keys

| Key | Description |
|-----|-------------|
| `:cljw/test-paths` | Test source directories for `cljw test` |

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `CLJW_HOME` | `~/.cljw` | Cache directory for git deps |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error |
| 2 | Compilation/analysis error |
