#!/usr/bin/env bash
# test/e2e/phase16_wasm_require_component.sh — W1 require-a-component (D-404 / ADR-0135).
# A Wasm component's exports become callable Vars in a namespace via
# cljw.wasm/require-component (a thin Clojure layer over the wasm/ primitives +
# clojure.core/intern). Exercises: :as ns creation, export-name cleanup
# (#[constructor]/#[method] markers stripped), cached-handle reuse, resource chain.
#
# OPT-IN, like phase16_wasm_component.sh: builds `-Dwasm` and is NOT in the default
# per-commit gate. The zwasm dep resolves from
# the tag pin in build.zig.zon (fetched on any host).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved? check the build.zig.zon pin)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

out="$("$BIN" test/e2e/fixtures/wasm_require_component_probe.clj 2>&1)" || fail "cljw exited non-zero:
$out"

for marker in \
  "PASS require-component-greet" \
  "PASS require-component-reuse" \
  "PASS require-component-resource" \
  "PASS require-component-refer"; do
  grep -q "$marker" <<<"$out" || fail "missing: $marker
$out"
done
grep -q "^DONE$" <<<"$out" || fail "fixture did not run to completion:
$out"

# --- ADR-0135 Amendment 1: the STATIC `ns` `:require` string-libspec form ---
# `(ns app (:require ["x.wasm" :as g] ["y.wasm" :refer [f]]))` — desugars to the
# require-component worker. Same component fixtures, via the new-code worldview.
ns_out="$("$BIN" test/e2e/fixtures/wasm_ns_require_component_probe.clj 2>&1)" || fail "ns :require component fixture exited non-zero:
$ns_out"
for marker in \
  "PASS ns-require-greet" \
  "PASS ns-require-arglists" \
  "PASS ns-require-resource" \
  "PASS ns-require-refer"; do
  grep -q "$marker" <<<"$ns_out" || fail "missing: $marker
$ns_out"
done
grep -q "^DONE$" <<<"$ns_out" || fail "ns :require fixture did not run to completion:
$ns_out"

# --- ADR-0135 A2: EXPLICIT-relative `./` resolves against the SOURCE file's dir ---
# Run from a DIFFERENT cwd (/tmp) with an absolute script path; `./greet_component.wasm`
# must resolve next to the .clj (source-relative), not relative to cwd. Proves the
# deps.edn-free CLI-handy resolution.
abs_fixture="$(pwd)/test/e2e/fixtures/wasm/ns_source_relative.clj"
abs_bin="$(pwd)/$BIN"
srcrel_out="$(cd /tmp && "$abs_bin" "$abs_fixture" 2>&1)" || fail "source-relative ns :require failed (cwd=/tmp):
$srcrel_out"
grep -q "src-rel: Hello, rel!" <<<"$srcrel_out" || fail "source-relative './' did not resolve against the source dir:
$srcrel_out"

# --- ADR-0159 (D-404 Impl E): resource lifecycle — own-handle wrapper + drop ---
rd_out="$("$BIN" test/e2e/fixtures/wasm_resource_drop_probe.clj 2>&1)" \
  || fail "resource drop fixture exited non-zero:
$rd_out"
for marker in \
  "PASS resource-roundtrip" \
  "PASS resource-drop" \
  "PASS resource-use-after-drop-traps" \
  "PASS resource-double-drop-idempotent" \
  "PASS with-resource-body-live" \
  "PASS with-resource-drops-at-scope-exit"; do
  grep -q "$marker" <<<"$rd_out" || fail "missing: $marker
$rd_out"
done
grep -q "^DONE$" <<<"$rd_out" || fail "resource drop fixture did not complete:
$rd_out"
echo "PASS resource-lifecycle -> own-handle wrapper + drop + use-after-drop trap + with-resource"

# --- D-568: a resource from a single-module component has no resource table ---
# zwasm's `.single` variant cannot drop a resource; the error must name that
# structural condition, not report a guest trap.
nt_out="$("$BIN" test/e2e/fixtures/wasm_resource_no_table_probe.clj 2>&1)" \
  || fail "resource no-table fixture exited non-zero:
$nt_out"
grep -q "PASS resource-drop-no-table" <<<"$nt_out" || fail "missing: PASS resource-drop-no-table
$nt_out"
echo "PASS resource-drop-no-table -> single-module drop names the missing resource table"

# --- ADR-0135 A2 (D-404 Impl E): a BARE component name resolves via the CLASSPATH ---
# `(:require ["greet_component.wasm" :as g])` with `-cp test/e2e/fixtures/wasm` — the
# bare name (no `./` or `/`) is searched on the classpath, like a `.clj` lib. The
# component is NOT in cwd, only on `-cp`, so a cwd-relative resolve would miss.
cp_out="$("$BIN" test/e2e/fixtures/wasm/ns_classpath_require.clj -cp test/e2e/fixtures/wasm 2>&1)" \
  || fail "classpath bare-name component :require failed:
$cp_out"
grep -q "classpath: Hello, cp!" <<<"$cp_out" \
  || fail "bare component name did not resolve via the classpath (-cp):
$cp_out"
echo "PASS ns-require-classpath -> bare name resolved on -cp"

# --- ADR-0158 (D-404 Impl D): `cljw build` embeds the :require'd component bytes ---
# Build the source-relative script FROM THE REPO ROOT so the baked component path
# is RELATIVE (`test/e2e/fixtures/wasm/./greet_component.wasm`). Then run the
# produced binary FROM /tmp, where that relative path does NOT resolve on disk —
# a self-contained binary must still greet from the EMBEDDED bytes (no sidecar).
# (Were the bytes NOT embedded, the FS fallback would miss and the run would fail,
# so this proves the single-binary contract, not just "it happens to work".)
embed_bin="$(mktemp -u /tmp/cljw_embed_XXXXXX)"
build_log="$("$BIN" build test/e2e/fixtures/wasm/ns_source_relative.clj -o "$embed_bin" 2>&1)" \
  || fail "cljw build (component embed) failed:
$build_log"
grep -q "embedded 1 Wasm component" <<<"$build_log" \
  || fail "build did not log the embedded component (harvest broken):
$build_log"
embed_out="$(cd /tmp && "$embed_bin" 2>&1)" \
  || fail "embedded-component binary exited non-zero (cwd=/tmp, no .wasm sidecar):
$embed_out"
grep -q "src-rel: Hello, rel!" <<<"$embed_out" \
  || fail "embedded component did not load from memory (single-binary broken):
$embed_out"
rm -f "$embed_bin"
echo "PASS build-embed-component -> self-contained single binary"

# A non-wasm build must NOT resolve cljw.wasm (the wasm/ ns is absent) — the
# gating is verified implicitly by the default gate (this step is -Dwasm-only).

echo
echo "Phase 16 / wasm require-a-component (W1) + ns :require (ADR-0135 Am.1) + build embed (ADR-0158): all green."
