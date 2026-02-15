# deps.edn Implementation Plan

> Implementation plan for ClojureWasm deps.edn support.
> Reference: `private/alpha_plan/19_deps_edn_design.md` (full spec mapping),
> `private/alpha_plan/20_deps_edn_practical.md` (practical design, Japanese).

## Design Principles

1. **Use deps.edn** — no custom format (unlike bb.edn, shadow-cljs.edn)
2. **CW-compatible deps.edn works on upstream Clojure** — CW-specific keys use
   `:cljw/*` namespace. Upstream `clj` ignores unknown keys, so the same
   deps.edn works in both environments
3. **Zero-config still works** — no deps.edn required. This is CW's
   differentiator. Maintain it
4. **Explicit dependency resolution** — `cljw -P` resolves deps ahead of time.
   Upstream's "wait on first startup" UX is bad. CW keeps 5ms startup
5. **Unsupported features produce clear errors** — e.g., `:mvn/version` →
   "Maven dependencies not supported yet. Use :git/url or :local/root"

---

## Feature Tiers

### Tier 1: Daily use (v1 required)

| Key / Feature      | Purpose                        | CW Status                      |
|--------------------|--------------------------------|--------------------------------|
| `:paths`           | Source directories              | Existing. Keep as-is           |
| `:deps`            | Dependency declarations         | git + local. Extend existing   |
| `:aliases`         | Environment switching           | New                            |
| `:extra-paths`     | Add paths via alias             | New                            |
| `:extra-deps`      | Add deps via alias              | New                            |
| `:main-opts`       | Args for `-M` mode             | New                            |
| `:exec-fn`         | Function for `-X` mode         | New                            |
| `:exec-args`       | Args for `-X` mode             | New                            |
| `:git/url`         | Git repository URL              | Existing. Direct URL strings   |
| `:git/sha`         | Git commit SHA                  | Existing                       |
| `:git/tag`         | Git tag                         | New (display + sha validation) |
| `:local/root`      | Local directory                 | Existing                       |
| `:deps/root`       | Monorepo subdirectory           | New                            |

### Tier 2: Occasional use (v1 scope)

| Key / Feature      | Purpose                        | CW Status                      |
|--------------------|--------------------------------|--------------------------------|
| `:ns-default`      | Default ns for `-X` unqualified fns | New                       |
| `:ns-aliases`      | Ns aliases for `-X`            | New                            |
| `-Spath`           | Show load paths                 | New                            |
| `-P`               | Resolve deps only (git clone)   | New                            |
| `-Srepro`          | Exclude user config             | New                            |

### Tier 3: Future

| Key / Feature      | Purpose                        | Timeline                       |
|--------------------|--------------------------------|--------------------------------|
| `:mvn/version`     | Clojars pure-clj libraries      | v2 (JAR extraction approach)   |
| `-T` (Tool mode)   | Tool install + exec             | v2 (CW native binary tools)    |
| `:override-deps`   | Force version override          | v2 (after transitive resolve)  |
| `-Stree`           | Dependency tree display         | v2 (after transitive resolve)  |

### Never supported

| Key / Feature      | Reason                                                     |
|--------------------|------------------------------------------------------------|
| `:mvn/repos`       | Custom Maven repos — not needed                            |
| `:mvn/local-repo`  | Maven local cache — CW uses own cache                      |
| `:jvm-opts`        | No JVM                                                     |
| `:classpath-overrides` | No classpath concept                                   |
| `-J` flags         | No JVM                                                     |
| S3 repositories    | JVM ecosystem                                              |

---

## Library Naming and URL Resolution

### io.github pattern

Upstream resolves `io.github.user/repo` to `https://github.com/user/repo`.
This Java package naming convention is confusing. CW recommends direct URL
but supports the pattern for compatibility.

```clojure
;; Recommended: direct URL (clear)
{:deps {medley/medley {:git/url "https://github.com/weavejester/medley"
                       :git/tag "1.8.0" :git/sha "a1b2c3d"}}}

;; Upstream-compatible: io.github pattern (CW resolves this too)
{:deps {io.github.weavejester/medley {:git/tag "1.8.0" :git/sha "a1b2c3d"}}}

;; Local
{:deps {my-utils/my-utils {:local/root "../my-utils"}}}
```

Implementation: support `io.github.*` / `io.gitlab.*` → URL inference internally.
Reason: "CW deps.edn works on upstream" requires accepting upstream patterns.

---

## CLI Design: Coexistence with Existing Flags

### Current cljw CLI

```
cljw                        REPL
cljw file.clj               File execution
cljw -e '(+ 1 2)'           Expression eval
cljw test [files...]        Test execution
cljw --tree-walk file.clj   TreeWalk backend
cljw --dump-bytecode file.clj  Bytecode dump
cljw --nrepl-server          nREPL server
cljw --port=N                nREPL port
cljw -v / --version          Version
cljw -h / --help             Help
```

### deps.edn CLI additions

```
cljw -A:dev                  REPL + alias
cljw -A:dev:test             REPL + multiple aliases
cljw -M:dev file.clj         Main mode + alias + file
cljw -M:dev -m my-app.core   Main mode + alias + ns -main
cljw -X:build my/task        Exec mode
cljw -X:build my/task :k v   Exec mode + args
cljw -P                      Resolve deps only (git clone)
cljw -Spath                  Show load paths
cljw -Sdeps '{:deps {...}}'  Additional deps
cljw -Srepro                 Exclude user config
cljw -Sforce                 Ignore cache
cljw -Sverbose               Debug output
```

### Coexistence rules

1. **Single `-` = upstream-compatible**: `-A`, `-M`, `-X`, `-P`, `-S*`, `-e`, `-m`, `-h`
2. **Double `--` = CW-specific**: `--tree-walk`, `--dump-bytecode`, `--nrepl-server`, `--version`
3. **Subcommands = CW-specific**: `test`
4. **Combinable**: `cljw -A:dev --tree-walk file.clj`, `cljw -A:dev test`

### Parse priority

```
1. Subcommand: args[1] == "test" → test mode
2. deps.edn flags: -A, -M, -X, -P, -S* → deps.edn mode
3. CW flags: --tree-walk, --dump-bytecode, --nrepl-server, --version, -e, -h
4. File path: *.clj → file execution
5. Fallback: REPL
```

---

## Dependency Resolution

### Basic flow: explicit resolve → cache → fast startup

```
cljw -P                  # Resolve deps (git clone + checkout)
                         # Network access happens ONLY here
cljw -M:dev my-app.clj  # Startup (uses cached deps, 5ms)
```

- **`cljw -P`**: Explicitly resolve dependencies. Git clone + checkout
- **Normal startup**: Read from `.cljw-cache/`. If unresolved →
  error: "Dependencies not resolved. Run `cljw -P` first."
- **Zero-config**: No deps.edn → no resolution needed. Instant startup

### Resolution algorithm

```
Read deps.edn
  ↓
Merge aliases (-A:dev:test → merge extra-deps, extra-paths)
  ↓
For each dep:
  :local/root → verify dir exists + recursively read deps.edn
  :git/url + :git/sha → check cache in ~/.cljw/gitlibs/
    cached → OK
    not cached → git clone + checkout
    → recursively read dep's deps.edn
  :mvn/version → ERROR "Maven dependencies not supported yet"
  ↓
Build load paths list (project paths + dep paths)
  ↓
Write cache: .cljw-cache/<hash>.paths
```

### Transitive resolution (v1 scope)

v1 resolves "direct deps + 1 level":

```
my-project
├── deps.edn {:deps {lib-a {:local/root "../lib-a"}
                     lib-b {:git/url "..." :git/sha "..."}}}
│
├── lib-a/deps.edn {:deps {lib-c {:local/root "../lib-c"}}}
│   └── lib-c → add paths (lib-c's deps NOT resolved)
│
└── lib-b (git) → clone + add paths
    └── lib-b/deps.edn {:deps {lib-d {...}}}
        └── lib-d → add paths (lib-d's deps NOT resolved)
```

Depth limit 2. Covers most practical cases.
Full transitive resolution (newest-wins algorithm) in v2.

### Unsupported deps in transitive chain

```
;; lib-a/deps.edn
{:deps {some-java-lib {:mvn/version "1.2.3"}}}
```

→ Warning (not error):
```
WARNING: Skipping dependency some-java-lib — Maven coordinates not supported.
  in: lib-a/deps.edn
```

→ But if Leiningen `project.clj` found:
```
ERROR: lib-a uses project.clj (Leiningen). ClojureWasm requires deps.edn.
```

---

## `-T` Tool Mode Vision (Future)

CW's unique advantage: AOT + binary embedding → distribute tools as native
binaries (not shell wrappers like babashka's bbin).

```bash
# Install tool (git fetch → build → place in ~/.cljw/bin/)
cljw -Tinstall io.github.user/my-tool :git/tag v1.0

# Run tool (native binary, 5ms startup)
cljw -T my-tool :arg1 val1
```

Staged implementation:
1. v1: No `-T` (out of scope)
2. v2: `-T` for script execution
3. v3: `-Tinstall` for native binary generation + install

---

## cljw.edn → deps.edn Migration

| cljw.edn            | deps.edn                       |
|----------------------|--------------------------------|
| `:paths ["src"]`     | `:paths ["src"]`               |
| `:test-paths ["t"]`  | `:cljw/test-paths ["t"]`       |
| `:main my.ns`        | `:cljw/main my.ns`             |
| `:deps {...}`        | `:deps {...}`                   |
| `:wasm-deps {...}`   | `:cljw/wasm-deps {...}`         |

Priority:
1. `deps.edn` exists → use it (ignore cljw.edn)
2. No `deps.edn`, `cljw.edn` exists → read cljw.edn + deprecation warning
3. Neither → zero-config

---

## Error Messages

```
# Maven dependency
ERROR: Maven dependency not supported: metosin/malli {:mvn/version "0.16.4"}
  Use :git/url + :git/sha instead, or wait for future Maven support.

# Leiningen
ERROR: Leiningen project.clj found in dependency lib-a.
  ClojureWasm requires deps.edn format.

# JVM opts
WARNING: :jvm-opts ignored — ClojureWasm is not a JVM runtime.
  in alias :dev

# Unresolved deps
ERROR: Dependencies not resolved. Run `cljw -P` to fetch dependencies.
  Missing: medley/medley (git), my-lib/my-lib (git)

# Git clone failure
ERROR: Failed to clone https://github.com/user/repo
  git error: Repository not found
  Check the :git/url in deps.edn

# SHA mismatch
ERROR: Git tag "v1.0" does not match SHA "abc1234" in repo user/repo
  Tag points to: def5678
  Fix the :git/sha in deps.edn
```

---

## Test Repository

A single test repository for verifying git dependency resolution:

- **Repo**: `github.com/chaploud/cljw-test-deps`
- **Purpose**: Contains sample Clojure source files for testing `:git/url`,
  `:git/sha`, `:git/tag`, `:deps/root`, and transitive deps
- **Structure** (evolves as tasks progress):
  ```
  cljw-test-deps/
  ├── deps.edn            # declares own deps (for transitive tests)
  ├── src/
  │   └── test_dep/
  │       └── core.clj    # (ns test-dep.core) (defn greet [x] (str "Hello, " x))
  ├── sub-lib/             # for :deps/root testing
  │   ├── deps.edn
  │   └── src/
  │       └── sub_lib/
  │           └── util.clj
  └── README.md
  ```
- **Tags**: `v0.1.0`, `v0.2.0` etc. for `:git/tag` testing
- **Policy**: One repo, overwrite/update as needed. Don't create multiple.

---

## Implementation Tasks (Phase 66+)

### Phase 66: deps.edn Foundation

| #    | Task                                    | Est.   | Depends |
|------|-----------------------------------------|--------|---------|
| 66.1 | deps.edn parser (EDN reader + schema)   | 4-6h   | —       |
| 66.2 | Alias resolution engine                 | 3-4h   | 66.1    |
| 66.3 | -A/-M/-X/-P CLI flag parsing            | 4-6h   | 66.2    |
| 66.4 | -X exec mode (fn invoke + arg parsing)  | 3-4h   | 66.3    |
| 66.5 | -Spath/-Sdeps/-Srepro/-Sforce           | 2-3h   | 66.3    |

### Phase 67: Git Dependencies

| #    | Task                                    | Est.   | Depends |
|------|-----------------------------------------|--------|---------|
| 67.1 | Create test repo (chaploud/cljw-test-deps) | 1h  | —       |
| 67.2 | Git clone + checkout (shell out to git) | 3-4h   | 66.1    |
| 67.3 | io.github/io.gitlab URL inference       | 1-2h   | 67.2    |
| 67.4 | :git/tag + :deps/root support           | 2-3h   | 67.2    |
| 67.5 | ~/.cljw/gitlibs/ cache management       | 2-3h   | 67.2    |

### Phase 68: Integration

| #    | Task                                    | Est.   | Depends |
|------|-----------------------------------------|--------|---------|
| 68.1 | Transitive dep resolution (depth 2)     | 3-4h   | 67.2    |
| 68.2 | .cljw-cache/ path cache                 | 2-3h   | 68.1    |
| 68.3 | User config (~/.config/cljw/)           | 2-3h   | 66.1    |
| 68.4 | cljw.edn fallback + deprecation warning | 1-2h   | 66.1    |
| 68.5 | Error messages (Maven/Lein/etc.)        | 1-2h   | 66.1    |
| 68.6 | cljw test alias integration             | 2-3h   | 66.2    |
| 68.7 | E2E tests (deps.edn project scenarios)  | 3-4h   | 66-68   |

**Total estimate**: ~35-50h (3 phases)

---

## Examples

### Zero-config (no deps.edn)

```bash
mkdir my-project && cd my-project && mkdir src
echo '(ns my-app.core) (defn -main [] (println "Hello"))' > src/my_app/core.clj
cljw -m my-app.core    # auto-detects src/, works
```

### Simple project

```clojure
;; deps.edn
{:paths ["src"]
 :cljw/main my-app.core
 :cljw/test-paths ["test"]}
```

### Git dependencies

```clojure
{:paths ["src"]
 :deps {medley/medley {:git/url "https://github.com/weavejester/medley"
                       :git/tag "1.8.0" :git/sha "a1b2c3d"}
        my-utils/my-utils {:local/root "../shared-utils"}}
 :cljw/main my-app.core}
```

```bash
cljw -P          # resolve (clone medley)
cljw             # REPL (medley + my-utils on load path)
```

### Aliases

```clojure
{:paths ["src"]
 :deps {medley/medley {:git/url "https://github.com/weavejester/medley"
                       :git/tag "1.8.0" :git/sha "a1b2c3d"}}
 :cljw/main my-app.core
 :cljw/test-paths ["test"]
 :aliases {:dev {:extra-paths ["dev" "resources"]
                 :extra-deps {my/dev-tools {:local/root "../dev-tools"}}
                 :main-opts ["-m" "my-app.dev"]}
           :test {:extra-deps {my/test-utils {:local/root "../test-utils"}}}
           :build {:exec-fn my-app.build/release
                   :exec-args {:target "native"}}}}
```

```bash
cljw -P                        # resolve all deps
cljw -A:dev                    # REPL with dev paths + deps
cljw -M:dev                    # run dev's -main
cljw -A:dev test               # tests in dev environment
cljw -X:build :target "wasm"   # invoke build/release function
```

### Wasm FFI

```clojure
{:paths ["src"]
 :deps {io.github.user/clj-helpers {:git/tag "v1.0" :git/sha "abc1234"}}
 :cljw/wasm-deps {"math" {:path "wasm/math.wasm"}}}
```
