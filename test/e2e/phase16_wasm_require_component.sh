#!/usr/bin/env bash
# test/e2e/phase16_wasm_require_component.sh — W1 require-a-component (D-404 / ADR-0135).
# A Wasm component's exports become callable Vars in a namespace via
# cljw.wasm/require-component (a thin Clojure layer over the wasm/ primitives +
# clojure.core/intern). Exercises: :as ns creation, export-name cleanup
# (#[constructor]/#[method] markers stripped), cached-handle reuse, resource chain.
#
# OPT-IN, like phase16_wasm_component.sh: builds `-Dwasm` and is NOT in the default
# per-commit gate. During the local-accumulation phase the zwasm dep resolves via
# the RELATIVE-path zon (sibling ../zwasm_from_scratch with REQ-7), so Mac-local.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved? need ../zwasm_from_scratch with REQ-7)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

out="$("$BIN" test/e2e/fixtures/wasm_require_component_probe.clj 2>&1)" || fail "cljw exited non-zero:
$out"

for marker in \
  "PASS require-component-greet" \
  "PASS require-component-reuse" \
  "PASS require-component-resource" \
  "PASS require-component-refer"; do
  echo "$out" | grep -q "$marker" || fail "missing: $marker
$out"
done
echo "$out" | grep -q "^DONE$" || fail "fixture did not run to completion:
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
  echo "$ns_out" | grep -q "$marker" || fail "missing: $marker
$ns_out"
done
echo "$ns_out" | grep -q "^DONE$" || fail "ns :require fixture did not run to completion:
$ns_out"

# --- ADR-0135 A2: EXPLICIT-relative `./` resolves against the SOURCE file's dir ---
# Run from a DIFFERENT cwd (/tmp) with an absolute script path; `./greet_component.wasm`
# must resolve next to the .clj (source-relative), not relative to cwd. Proves the
# deps.edn-free CLI-handy resolution.
abs_fixture="$(pwd)/test/e2e/fixtures/wasm/ns_source_relative.clj"
abs_bin="$(pwd)/$BIN"
srcrel_out="$(cd /tmp && "$abs_bin" "$abs_fixture" 2>&1)" || fail "source-relative ns :require failed (cwd=/tmp):
$srcrel_out"
echo "$srcrel_out" | grep -q "src-rel: Hello, rel!" || fail "source-relative './' did not resolve against the source dir:
$srcrel_out"

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
echo "$build_log" | grep -q "embedded 1 Wasm component" \
  || fail "build did not log the embedded component (harvest broken):
$build_log"
embed_out="$(cd /tmp && "$embed_bin" 2>&1)" \
  || fail "embedded-component binary exited non-zero (cwd=/tmp, no .wasm sidecar):
$embed_out"
echo "$embed_out" | grep -q "src-rel: Hello, rel!" \
  || fail "embedded component did not load from memory (single-binary broken):
$embed_out"
rm -f "$embed_bin"
echo "PASS build-embed-component -> self-contained single binary"

# A non-wasm build must NOT resolve cljw.wasm (the wasm/ ns is absent) — the
# gating is verified implicitly by the default gate (this step is -Dwasm-only).

echo
echo "Phase 16 / wasm require-a-component (W1) + ns :require (ADR-0135 Am.1) + build embed (ADR-0158): all green."
