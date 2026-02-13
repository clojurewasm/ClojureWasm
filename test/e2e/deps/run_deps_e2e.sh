#!/usr/bin/env bash
# E2E tests for deps.edn support (Phase 67)
# Creates local git repos and tests git dependency resolution.
# Usage: bash test/e2e/deps/run_deps_e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLJW="$ROOT_DIR/zig-out/bin/cljw"

# Build ReleaseSafe if needed
if [ ! -f "$CLJW" ]; then
  echo "Building cljw..."
  (cd "$ROOT_DIR" && zig build -Doptimize=ReleaseSafe)
fi

PASS=0
FAIL=0
ERRORS=""
TMPDIR_BASE="/tmp/cljw-deps-e2e-$$"

cleanup() {
  rm -rf "$TMPDIR_BASE"
  rm -rf "$HOME/.cljw/gitlibs-e2e-$$"
}
trap cleanup EXIT

mkdir -p "$TMPDIR_BASE"

# Override HOME for gitlibs cache isolation (avoid polluting real cache)
ORIG_HOME="$HOME"
export HOME="$TMPDIR_BASE/fakehome"
mkdir -p "$HOME"

# Git needs author info (since we override HOME, .gitconfig is gone)
export GIT_AUTHOR_NAME="test"
export GIT_AUTHOR_EMAIL="test@test.com"
export GIT_COMMITTER_NAME="test"
export GIT_COMMITTER_EMAIL="test@test.com"

run_test() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  printf "  %-45s " "$name"
  if output=$(eval "$cmd" 2>&1); then
    if echo "$output" | grep -qF "$expected"; then
      echo "PASS"
      PASS=$((PASS + 1))
    else
      echo "FAIL (unexpected output)"
      FAIL=$((FAIL + 1))
      ERRORS="$ERRORS\n--- $name ---\nExpected: $expected\nGot: $output\n"
    fi
  else
    echo "FAIL (exit code $?)"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n--- $name ---\n$output\n"
  fi
}

run_test_stderr() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  printf "  %-45s " "$name"
  local output
  output=$(eval "$cmd" 2>&1) || true
  if echo "$output" | grep -qF "$expected"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected in stderr)"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n--- $name ---\nExpected: $expected\nGot: $output\n"
  fi
}

# === Setup: Create test git repo ===

GIT_REPO="$TMPDIR_BASE/test-dep-repo"
mkdir -p "$GIT_REPO/src/test_dep"
cat > "$GIT_REPO/src/test_dep/core.clj" << 'CLOJ'
(ns test-dep.core)
(defn greet [x] (str "Hello, " x))
CLOJ
cat > "$GIT_REPO/deps.edn" << 'CLOJ'
{:paths ["src"]}
CLOJ
(cd "$GIT_REPO" && git init -q && git add -A && git commit -q -m "v1")
V1_SHA=$(cd "$GIT_REPO" && git rev-parse HEAD)
(cd "$GIT_REPO" && git tag v0.1.0)

# Add sub-lib for :deps/root testing
mkdir -p "$GIT_REPO/sub-lib/src/sub_lib"
cat > "$GIT_REPO/sub-lib/src/sub_lib/util.clj" << 'CLOJ'
(ns sub-lib.util)
(defn add2 [x] (+ x 2))
CLOJ
cat > "$GIT_REPO/sub-lib/deps.edn" << 'CLOJ'
{:paths ["src"]}
CLOJ
(cd "$GIT_REPO" && git add -A && git commit -q -m "v2 with sub-lib")
V2_SHA=$(cd "$GIT_REPO" && git rev-parse HEAD)
(cd "$GIT_REPO" && git tag v0.2.0)

echo "=== deps.edn E2E Tests ==="
echo ""

# --- Test 1: Basic git dep with tag ---
PROJ1="$TMPDIR_BASE/proj1"
mkdir -p "$PROJ1/src/app"
cat > "$PROJ1/deps.edn" << EOF
{:paths ["src"]
 :deps {test-dep/test-dep {:git/url "$GIT_REPO"
                           :git/tag "v0.1.0"
                           :git/sha "$V1_SHA"}}}
EOF
cat > "$PROJ1/src/app/core.clj" << 'CLOJ'
(ns app.core (:require [test-dep.core :as td]))
(println (td/greet "World"))
CLOJ
run_test "git dep + tag" \
  "cd $PROJ1 && $CLJW -P && $CLJW src/app/core.clj" \
  "Hello, World"

# --- Test 2: Tag mismatch error (must run before V2_SHA is cached) ---
PROJ3="$TMPDIR_BASE/proj3"
mkdir -p "$PROJ3/src"
cat > "$PROJ3/deps.edn" << EOF
{:paths ["src"]
 :deps {test-dep/test-dep {:git/url "$GIT_REPO"
                           :git/tag "v0.1.0"
                           :git/sha "$V2_SHA"}}}
EOF
echo '(println "ok")' > "$PROJ3/src/test.clj"
run_test_stderr "tag mismatch error" \
  "cd $PROJ3 && $CLJW -P" \
  "ERROR: Git tag \"v0.1.0\" does not match"

# --- Test 3: :deps/root (monorepo subdirectory) ---
PROJ2="$TMPDIR_BASE/proj2"
mkdir -p "$PROJ2/src/app"
cat > "$PROJ2/deps.edn" << EOF
{:paths ["src"]
 :deps {sub-lib/sub-lib {:git/url "$GIT_REPO"
                          :git/tag "v0.2.0"
                          :git/sha "$V2_SHA"
                          :deps/root "sub-lib"}}}
EOF
cat > "$PROJ2/src/app/core.clj" << 'CLOJ'
(ns app.core (:require [sub-lib.util :as u]))
(println (u/add2 40))
CLOJ
run_test "deps/root monorepo" \
  "cd $PROJ2 && $CLJW -P && $CLJW src/app/core.clj" \
  "42"

# --- Test 4: -Sforce cache bypass ---
PROJ4="$TMPDIR_BASE/proj4"
mkdir -p "$PROJ4/src"
cat > "$PROJ4/deps.edn" << EOF
{:paths ["src"]
 :deps {test-dep/test-dep {:git/url "$GIT_REPO"
                           :git/tag "v0.1.0"
                           :git/sha "$V1_SHA"}}}
EOF
echo '(println "ok")' > "$PROJ4/src/test.clj"
# First resolve (creates cache)
(cd "$PROJ4" && "$CLJW" -P >/dev/null 2>&1)
# Second resolve with -Sforce should re-fetch
run_test_stderr "-Sforce cache bypass" \
  "cd $PROJ4 && $CLJW -Sforce -P" \
  "Fetching"

# --- Test 5: -Spath shows load paths ---
run_test "-Spath with deps" \
  "cd $PROJ1 && $CLJW -Spath" \
  "src"

# --- Test 6: Local dep ---
LOCAL_DEP="$TMPDIR_BASE/local-dep"
mkdir -p "$LOCAL_DEP/src/local_dep"
cat > "$LOCAL_DEP/src/local_dep/core.clj" << 'CLOJ'
(ns local-dep.core)
(defn double-it [x] (* x 2))
CLOJ
PROJ6="$TMPDIR_BASE/proj6"
mkdir -p "$PROJ6/src/app"
cat > "$PROJ6/deps.edn" << EOF
{:paths ["src"]
 :deps {local-dep/local-dep {:local/root "$LOCAL_DEP"}}}
EOF
cat > "$PROJ6/src/app/core.clj" << 'CLOJ'
(ns app.core (:require [local-dep.core :as ld]))
(println (ld/double-it 21))
CLOJ
run_test "local dep" \
  "cd $PROJ6 && $CLJW src/app/core.clj" \
  "42"

# --- Test 7: -X exec mode ---
PROJ7="$TMPDIR_BASE/proj7"
mkdir -p "$PROJ7/src/my_app"
cat > "$PROJ7/deps.edn" << 'EOF'
{:paths ["src"]
 :aliases {:build {:exec-fn my-app.build/release
                   :exec-args {:target "native"}}}}
EOF
cat > "$PROJ7/src/my_app/build.clj" << 'CLOJ'
(ns my-app.build)
(defn release [opts] (println "Build:" opts))
CLOJ
run_test "-X exec mode" \
  "cd $PROJ7 && $CLJW -X:build" \
  "Build:"

# --- Test 8: -M main mode ---
PROJ8="$TMPDIR_BASE/proj8"
mkdir -p "$PROJ8/src/my_app"
cat > "$PROJ8/deps.edn" << 'EOF'
{:paths ["src"]
 :aliases {:run {:main-opts ["-m" "my-app.core"]}}}
EOF
cat > "$PROJ8/src/my_app/core.clj" << 'CLOJ'
(ns my-app.core)
(defn -main [] (println "Main via -M!"))
CLOJ
run_test "-M main mode" \
  "cd $PROJ8 && $CLJW -M:run" \
  "Main via -M!"

# --- Test 9: deps.edn priority over cljw.edn ---
PROJ9="$TMPDIR_BASE/proj9"
mkdir -p "$PROJ9/src/app"
cat > "$PROJ9/deps.edn" << 'EOF'
{:paths ["src"]}
EOF
cat > "$PROJ9/cljw.edn" << 'EOF'
{:paths ["other"]}
EOF
cat > "$PROJ9/src/app/core.clj" << 'CLOJ'
(ns app.core)
(println "deps.edn wins")
CLOJ
run_test "deps.edn priority over cljw.edn" \
  "cd $PROJ9 && $CLJW src/app/core.clj" \
  "deps.edn wins"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "=== Failures ==="
  printf "$ERRORS"
  exit 1
fi
