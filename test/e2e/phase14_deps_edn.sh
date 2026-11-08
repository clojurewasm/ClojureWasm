#!/usr/bin/env bash
# test/e2e/phase14_deps_edn.sh
#
# Convergence Campaign Stage 1.2 — deps.edn source resolution.
# A `./deps.edn` in the working directory contributes its `:paths` and
# Maven coordinates resolve Clojure source jars and compile/runtime POM deps.
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

# Case 4 below was written for the old skip-only resolver; this lane now
# requires Maven coordinates to resolve (the hermetic fixture below tests it).
# --- Case 4: :mvn/version is SKIPPED (source-only), resolution proceeds; a
#     non-clojure mvn coord is summary-warned on stderr (ADR-0101 amendment) ---
if false; then # superseded historical skip-only assertions
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
fi

# --- Case 4b: org.clojure/clojure :mvn is silently provided (cw itself, no
#     warning); a dep deps.edn with no :paths defaults to src/ (medley shape) ---
med="$WORK/med"; mkdir -p "$med/app/src/app" "$med/dep/src/deplib"
printf '(ns deplib.core)\n(defn v [] "dep-src")\n' > "$med/dep/src/deplib/core.clj"
# The fixture above supplies a local Maven repo instead of a remote service.
printf '{:deps {org.clojure/clojure {:mvn/version "1.11.0"}}}\n' > "$med/dep/deps.edn"  # no :paths → src default
# Keep the :clojure-provided test outside the legacy block.
printf '{:paths ["src"] :deps {deplib/deplib {:local/root "../dep"}}}\n' > "$med/app/deps.edn"
out="$(cd "$med/app" && "$BIN" -e "(require 'deplib.core) (deplib.core/v)" 2>&1)"
[[ "$(last_line "$out")" == '"dep-src"' ]] || fail "medley-shape: no-:paths dep src default failed: '$(last_line "$out")'"
case "$out" in
    *org.clojure/clojure*) fail "medley-shape: org.clojure/clojure should be silently provided, not warned" ;;
    *) echo "PASS deps_mvn_clojure_provided -> src default + no clojure warning" ;;
esac
# --- Case 4c: local Maven jar sources and transitive runtime POM deps ---
mvn="$WORK/mvn"; mkdir -p "$mvn/repo/com/example/lib/1.0" "$mvn/repo/com/example/child/1.0" "$mvn/jars/lib/mp" "$mvn/jars/child/dep"
printf '(ns mp.core)\n(defn ok [] :ok)\n' > "$mvn/jars/lib/mp/core.clj"
printf '(ns dep.core)\n(defn ok [] :transitive)\n' > "$mvn/jars/child/dep/core.clj"
printf '(ns mp.core)\n(defn ok [] :cljw)\n' > "$mvn/jars/lib/mp/core.cljw"
(cd "$mvn/jars/lib" && zip -q "$mvn/repo/com/example/lib/1.0/lib-1.0.jar" mp/core.clj)
(cd "$mvn/jars/lib" && zip -q "$mvn/repo/com/example/lib/1.0/lib-1.0.jar" mp/core.cljw)
(cd "$mvn/jars/child" && zip -q "$mvn/repo/com/example/child/1.0/child-1.0.jar" dep/core.clj)
printf '<project><dependencies><dependency><groupId>com.example</groupId><artifactId>child</artifactId><version>1.0</version><scope>runtime</scope></dependency></dependencies></project>\n' > "$mvn/repo/com/example/lib/1.0/lib-1.0.pom"
printf '<project/>\n' > "$mvn/repo/com/example/child/1.0/child-1.0.pom"
printf '{:deps {com.example/lib {:mvn/version "1.0"}}}\n' > "$mvn/deps.edn"
for run in 1 2; do
    got="$(cd "$mvn" && M2_REPO="$mvn/repo" CLJW_HOME="$mvn/cache" "$BIN" -e "(require 'mp.core 'dep.core) [(mp.core/ok) (dep.core/ok)]")"
    [[ "$(last_line "$got")" == '[:cljw :transitive]' ]] || fail "mvn: run $run got '$(last_line "$got")'"
# The .cljw entry takes precedence over the .clj entry in the same jar.
done
[[ -f "$mvn/cache/mvn/com/example/lib/1.0/.complete" ]] || fail "mvn: extraction cache missing"
echo "PASS deps_mvn_local_jar -> sources + transitive + cache hit"

# --- Case 4c2: project version and nested POM properties resolve transitive versions ---
prop="$WORK/properties"; mkdir -p "$prop/repo/com/example/parent/1.0" "$prop/repo/com/example/child/1.0" "$prop/repo/com/example/nested/2.0" "$prop/src/child" "$prop/src/nested" "$prop/app"
printf '(ns child.core)\n(defn ok [] :project-version)\n' > "$prop/src/child/core.clj"
printf '(ns nested.core)\n(defn ok [] :property-version)\n' > "$prop/src/nested/core.clj"
(cd "$prop/src" && zip -q "$prop/repo/com/example/child/1.0/child-1.0.jar" child/core.clj && zip -q "$prop/repo/com/example/nested/2.0/nested-2.0.jar" nested/core.clj)
(cd "$prop/src" && zip -q "$prop/repo/com/example/parent/1.0/parent-1.0.jar" child/core.clj)
printf '<project><properties><nested.version>2.0</nested.version></properties><dependencies><dependency><groupId>com.example</groupId><artifactId>child</artifactId><version>${project.version}</version></dependency><dependency><groupId>com.example</groupId><artifactId>nested</artifactId><version>${nested.version}</version></dependency></dependencies></project>\n' > "$prop/repo/com/example/parent/1.0/parent-1.0.pom"
printf '<project/>\n' > "$prop/repo/com/example/child/1.0/child-1.0.pom"
printf '<project/>\n' > "$prop/repo/com/example/nested/2.0/nested-2.0.pom"
printf '{:deps {com.example/parent {:mvn/version "1.0"}}}\n' > "$prop/app/deps.edn"
got="$(cd "$prop/app" && M2_REPO="$prop/repo" CLJW_HOME="$prop/cache" "$BIN" -e "(require 'child.core 'nested.core) [(child.core/ok) (nested.core/ok)]" 2>&1)"
[[ "$(last_line "$got")" == '[:project-version :property-version]' ]] || fail "mvn properties: $got"
[[ -f "$prop/cache/mvn/com/example/child/1.0/.complete" && -f "$prop/cache/mvn/com/example/nested/2.0/.complete" ]] || fail "mvn properties: transitive artifacts not extracted"
echo "PASS deps_mvn_pom_properties -> project.version and nested properties"

# --- Case 4d: remote Maven artifacts require same-repository checksums ---
remote="$WORK/remote"; mkdir -p "$remote/host/com/example/verified/1.0" "$remote/src/verified" "$remote/app"
printf '(ns verified.core)\n(defn ok [] :verified)\n' > "$remote/src/verified/core.clj"
(cd "$remote/src" && zip -q "$remote/host/com/example/verified/1.0/verified-1.0.jar" verified/core.clj)
printf '<project/>\n' > "$remote/host/com/example/verified/1.0/verified-1.0.pom"
for ext in jar pom; do
    artifact="$remote/host/com/example/verified/1.0/verified-1.0.$ext"
    sha1sum "$artifact" | cut -d' ' -f1 > "$artifact.sha1"
done
printf '{:deps {com.example/verified {:mvn/version "1.0"}}}\n' > "$remote/app/deps.edn"
remote_url="file://$remote/host"
got="$(cd "$remote/app" && M2_REPO="$remote/good-repo" CLJW_HOME="$remote/good-cache" CLJW_MVN_REPOS="$remote_url" "$BIN" -e "(require 'verified.core) (verified.core/ok)" 2>&1)"
[[ "$(last_line "$got")" == ':verified' ]] || fail "mvn checksum: good artifact: $got"
[[ -f "$remote/good-repo/com/example/verified/1.0/verified-1.0.jar" && -f "$remote/good-repo/com/example/verified/1.0/verified-1.0.pom" ]] || fail "mvn checksum: verified artifacts not installed"
printf 'tampered' >> "$remote/host/com/example/verified/1.0/verified-1.0.jar"
if got="$(cd "$remote/app" && M2_REPO="$remote/bad-repo" CLJW_HOME="$remote/bad-cache" CLJW_MVN_REPOS="$remote_url" "$BIN" -e "(require 'verified.core)" 2>&1)"; then
    fail "mvn checksum: tampered jar unexpectedly loaded"
fi
[[ "$got" == *"SHA-1 checksum mismatch"* && "$got" == *"$remote_url/com/example/verified/1.0/verified-1.0.jar"* ]] || fail "mvn checksum: missing URL diagnosis: $got"
[[ ! -f "$remote/bad-repo/com/example/verified/1.0/verified-1.0.jar" && ! -f "$remote/bad-repo/com/example/verified/1.0/verified-1.0.jar.tmp" ]] || fail "mvn checksum: bad jar installed or temp retained"
# Missing sidecars fail closed, including when another repository is configured.
mv "$remote/host/com/example/verified/1.0/verified-1.0.jar.sha1" "$remote/host/com/example/verified/1.0/verified-1.0.jar.sha1.hidden"
if got="$(cd "$remote/app" && M2_REPO="$remote/missing-repo" CLJW_HOME="$remote/missing-cache" CLJW_MVN_REPOS="$remote_url" "$BIN" -e "(require 'verified.core)" 2>&1)"; then
    fail "mvn checksum: missing sidecar unexpectedly loaded"
fi
[[ "$got" == *"missing SHA-1 checksum"* && "$got" == *"verified-1.0.jar"* ]] || fail "mvn checksum: missing sidecar diagnosis: $got"
[[ ! -f "$remote/missing-repo/com/example/verified/1.0/verified-1.0.jar" ]] || fail "mvn checksum: unchecked jar installed"
mv "$remote/host/com/example/verified/1.0/verified-1.0.jar.sha1.hidden" "$remote/host/com/example/verified/1.0/verified-1.0.jar.sha1"
# Restore the jar, then tamper only with the POM.
cp "$remote/good-repo/com/example/verified/1.0/verified-1.0.jar" "$remote/host/com/example/verified/1.0/verified-1.0.jar"
printf '<bad/>\n' >> "$remote/host/com/example/verified/1.0/verified-1.0.pom"
if got="$(cd "$remote/app" && M2_REPO="$remote/bad-pom-repo" CLJW_HOME="$remote/bad-pom-cache" CLJW_MVN_REPOS="$remote_url" "$BIN" -e "(require 'verified.core)" 2>&1)"; then
    fail "mvn checksum: tampered POM unexpectedly loaded"
fi
[[ "$got" == *"SHA-1 checksum mismatch"* && "$got" == *"verified-1.0.pom"* ]] || fail "mvn checksum: bad POM diagnosis: $got"
[[ ! -f "$remote/bad-pom-repo/com/example/verified/1.0/verified-1.0.pom" ]] || fail "mvn checksum: unchecked POM installed"
echo "PASS deps_mvn_checksum -> verified jar and pom; tampered jar and POM rejected"


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
