#!/usr/bin/env bash
# test/e2e/phase14_deps_edn.sh
#
# Convergence Campaign Stage 1.2 — deps.edn source resolution.
# A `./deps.edn` in the working directory contributes its `:paths` and
# `:local/root`/`:git/url` deps to the front of the require classpath.
# `:mvn/version` is SKIPPED (source-only, ADR-0101 amendment): resolution
# proceeds + a summary warning names the skipped coords, except
# `org.clojure/clojure` (cw itself, always satisfied). A dep deps.edn with no
# `:paths` defaults to `src/` (tools.deps convention). Layer 2 (e2e CLI).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { printf '%s' "$1" | tail -1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Case 1: :paths makes a ns under src/ requirable ---
proj="$WORK/proj1"; mkdir -p "$proj/src/myproj"
printf '{:paths ["src"]}\n' > "$proj/deps.edn"
printf '(ns myproj.core)\n(defn greet [] "hello-deps")\n' > "$proj/src/myproj/core.clj"
got="$(cd "$proj" && "$BIN" -e "(require 'myproj.core) (myproj.core/greet)" 2>/dev/null)"
[[ "$(last_line "$got")" == '"hello-deps"' ]] || fail "paths: got '$(last_line "$got")'"
echo "PASS deps_paths -> hello-deps"

# --- Case 2: control — without deps.edn the same src/ tree is NOT on the path ---
ctrl="$WORK/ctrl"; mkdir -p "$ctrl/src/myproj"
printf '(ns myproj.core)\n(defn greet [] "x")\n' > "$ctrl/src/myproj/core.clj"
if (cd "$ctrl" && "$BIN" -e "(require 'myproj.core)" >/dev/null 2>&1); then
    fail "control: require unexpectedly succeeded without deps.edn :paths"
fi
echo "PASS deps_control_no_edn -> require fails (proves :paths drove it)"

# --- Case 3: :local/root pulls in a sibling lib's :paths transitively ---
mono="$WORK/mono"; mkdir -p "$mono/app/src/app" "$mono/lib/src/lib"
printf '(ns lib.util)\n(defn tag [] "from-lib")\n' > "$mono/lib/src/lib/util.clj"
printf '{:paths ["src"]}\n' > "$mono/lib/deps.edn"
printf '{:paths ["src"] :deps {lib/lib {:local/root "../lib"}}}\n' > "$mono/app/deps.edn"
printf '(ns app.main)\n' > "$mono/app/src/app/main.clj"
got="$(cd "$mono/app" && "$BIN" -e "(require 'lib.util) (lib.util/tag)" 2>/dev/null)"
[[ "$(last_line "$got")" == '"from-lib"' ]] || fail "local-root: got '$(last_line "$got")'"
echo "PASS deps_local_root -> from-lib"

# --- Case 5: -A:alias activates :extra-paths (off by default) ---
al="$WORK/al"; mkdir -p "$al/src/base" "$al/dev/devns"
printf '{:paths ["src"] :aliases {:dev {:extra-paths ["dev"]}}}\n' > "$al/deps.edn"
printf '(ns base.core)\n(defn b [] "base")\n' > "$al/src/base/core.clj"
printf '(ns devns.tool)\n(defn t [] "dev-tool")\n' > "$al/dev/devns/tool.clj"
if (cd "$al" && "$BIN" -e "(require 'devns.tool)" >/dev/null 2>&1); then
    fail "alias: devns unexpectedly resolved without -A:dev"
fi
got="$(cd "$al" && "$BIN" -A:dev -e "(require 'devns.tool) (devns.tool/t)" 2>/dev/null)"
[[ "$(last_line "$got")" == '"dev-tool"' ]] || fail "alias: -A:dev got '$(last_line "$got")'"
echo "PASS deps_alias_extra_paths -> dev-tool (off without -A)"

# --- Case 4: :mvn/version is SKIPPED (source-only), resolution proceeds; a
#     non-clojure mvn coord is summary-warned on stderr (ADR-0101 amendment) ---
mvn="$WORK/mvn"; mkdir -p "$mvn/src/mp"
printf '{:paths ["src"] :deps {com.example/lib {:mvn/version "1.0"}}}\n' > "$mvn/deps.edn"
printf '(ns mp.core)\n(defn ok [] :ok)\n' > "$mvn/src/mp/core.clj"
# resolution does NOT abort: the :paths ns still loads despite the :mvn dep
got="$(cd "$mvn" && "$BIN" -e "(require 'mp.core) (mp.core/ok)" 2>/dev/null)"
[[ "$(last_line "$got")" == ':ok' ]] || fail "mvn-skip: :paths ns failed to load: '$(last_line "$got")'"
# the skipped non-clojure mvn coord is named in the stderr summary warning
warn="$(cd "$mvn" && "$BIN" -e "(+ 1 1)" 2>&1 1>/dev/null)"
case "$warn" in
    *skipped*com.example/lib*) echo "PASS deps_mvn_skip -> resolves + warns" ;;
    *) fail "mvn-skip: expected skip warning naming com.example/lib, got: $warn" ;;
esac

# --- Case 4b: org.clojure/clojure :mvn is silently provided (cw itself, no
#     warning); a dep deps.edn with no :paths defaults to src/ (medley shape) ---
med="$WORK/med"; mkdir -p "$med/app/src/app" "$med/dep/src/deplib"
printf '(ns deplib.core)\n(defn v [] "dep-src")\n' > "$med/dep/src/deplib/core.clj"
printf '{:deps {org.clojure/clojure {:mvn/version "1.11.0"}}}\n' > "$med/dep/deps.edn"  # no :paths → src default
printf '{:paths ["src"] :deps {deplib/deplib {:local/root "../dep"}}}\n' > "$med/app/deps.edn"
out="$(cd "$med/app" && "$BIN" -e "(require 'deplib.core) (deplib.core/v)" 2>&1)"
[[ "$(last_line "$out")" == '"dep-src"' ]] || fail "medley-shape: no-:paths dep src default failed: '$(last_line "$out")'"
case "$out" in
    *org.clojure/clojure*) fail "medley-shape: org.clojure/clojure should be silently provided, not warned" ;;
    *) echo "PASS deps_mvn_clojure_provided -> src default + no clojure warning" ;;
esac

# --- Case 6: :git/url resolves via a hermetic local bare repo (ADR-0101) ---
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP deps_git (git not on PATH)"
else
    g="$WORK/git"; mkdir -p "$g"
    gsrc="$g/lib-src"; mkdir -p "$gsrc/src/gitlib"
    printf '{:paths ["src"]}\n' > "$gsrc/deps.edn"
    printf '(ns gitlib.core)\n(defn hi [] "from-git")\n' > "$gsrc/src/gitlib/core.clj"
    ( cd "$gsrc" && git init -q && git add -A &&
      git -c user.email=t@t -c user.name=t commit -qm init )
    gsha="$(cd "$gsrc" && git rev-parse HEAD)"
    gbare="$g/bare.git"; git clone -q --bare "$gsrc" "$gbare" 2>/dev/null
    gproj="$g/proj"; mkdir -p "$gproj"
    printf '{:deps {gitlib/gitlib {:git/url "file://%s" :git/sha "%s"}}}\n' "$gbare" "$gsha" > "$gproj/deps.edn"
    got="$(cd "$gproj" && CLJW_HOME="$g/cache" "$BIN" -e "(require 'gitlib.core) (gitlib.core/hi)" 2>/dev/null)"
    [[ "$(last_line "$got")" == '"from-git"' ]] || fail "git: clone+resolve got '$(last_line "$got")'"
    # second run = cache hit (the sha dir exists, no re-clone)
    got2="$(cd "$gproj" && CLJW_HOME="$g/cache" "$BIN" -e "(require 'gitlib.core) (gitlib.core/hi)" 2>/dev/null)"
    [[ "$(last_line "$got2")" == '"from-git"' ]] || fail "git: cache-hit got '$(last_line "$got2")'"
    [[ -d "$g/cache/gitlibs/bare/$gsha" ]] || fail "git: cache dir not content-addressed on full sha"
    echo "PASS deps_git_file_url -> from-git (clone + cache-hit + full-sha layout)"
    # bad sha → clean lib-load failure, non-zero exit
    printf '{:deps {x/x {:git/url "file://%s" :git/sha "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}}\n' "$gbare" > "$gproj/deps.edn"
    if (cd "$gproj" && CLJW_HOME="$g/cache2" "$BIN" -e "(+ 1 1)" >/dev/null 2>&1); then
        fail "git: bad sha unexpectedly succeeded"
    fi
    echo "PASS deps_git_bad_sha -> clean failure"
fi

echo "ALL phase14_deps_edn PASS"
