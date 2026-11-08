#!/usr/bin/env bash
# test/e2e/phase16_wasm_polyglot.sh — the polyglot demo (docs/examples/polyglot)
# is a gated claim, not prose. Two legs:
#
#   1. The COMMITTED artifacts: run polyglot.clj against the checked-in C, Zig
#      and Rust guests (core modules + the WIT component). This is what a
#      reader gets by cloning and running the file.
#   2. The BUILD RECIPES: rebuild every guest whose toolchain is on PATH into a
#      scratch copy of the directory (zig is always here, it builds cljw; rustc
#      and go when present) and run the same probe there. A recipe in a source
#      header that stops producing a loadable module fails here, not in a
#      reader's terminal.
#
# The Go guest is never committed (it carries the Go runtime); leg 2 builds it
# when `go` is on PATH and the probe prints PASS go-command, otherwise the probe
# prints SKIP go-command and this test requires that line instead.
#
# hosts.cljc runs on cljw always, and on cljrs / JVM Clojure when those are on
# PATH (CLJRS_BIN overrides the cljrs lookup); every host present must print the
# same line.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved? check the build.zig.zon pin)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version))"
ABS_BIN="$(pwd)/$BIN"
DEMO="$(pwd)/docs/examples/polyglot"

# Portable time bound: GNU timeout, gtimeout (Homebrew coreutils), else none.
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

expect_probe() {  # $1 dir  $2 go-marker (PASS|SKIP)
  local out
  out="$(cd "$1" && run_bounded 60 "$ABS_BIN" polyglot.clj 2>&1)" \
    || fail "polyglot.clj exited non-zero in $1:
$out"
  for marker in "PASS c-kernel" "PASS zig-numeric" "PASS rust-core" "PASS rust-component" "$2 go-command" "DONE"; do
    grep -q "^$marker" <<<"$out" || fail "missing '$marker' in $1:
$out"
  done
}

# --- leg 1: the committed artifacts ---------------------------------------
[ -f "$DEMO/go/jsonsum.wasm" ] && go_marker=PASS || go_marker=SKIP
expect_probe "$DEMO" "$go_marker"
echo "PASS polyglot-committed -> C, Zig, Rust core, Rust component ($go_marker go)"

# --- leg 2: the build recipes, in a scratch copy ---------------------------
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cljw_polyglot_XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cp -R "$DEMO/." "$scratch/"
rm -f "$scratch/c/kernel.wasm" "$scratch/zig/numeric.wasm" "$scratch/go/jsonsum.wasm"

(cd "$scratch/c" && zig cc -target wasm32-freestanding -O2 -nostdlib \
   -Wl,--no-entry -Wl,--export-memory -Wl,-z,stack-size=65536 \
   kernel.c -o kernel.wasm) || fail "the C build recipe (zig cc) failed"
(cd "$scratch/zig" && zig build-exe numeric.zig -target wasm32-freestanding -O ReleaseSmall \
   -fno-entry -rdynamic -femit-bin=numeric.wasm) || fail "the Zig build recipe failed"
rebuilt="C, Zig"

if command -v rustc >/dev/null 2>&1 && rustc --print target-list 2>/dev/null | grep -q '^wasm32-unknown-unknown$' \
   && rustc --target wasm32-unknown-unknown --print sysroot >/dev/null 2>&1 \
   && [ -d "$(rustc --print sysroot)/lib/rustlib/wasm32-unknown-unknown" ]; then
  rm -f "$scratch/rust-core/fib.wasm"
  (cd "$scratch/rust-core" && rustc --target wasm32-unknown-unknown --crate-type cdylib \
     -C opt-level=s -C panic=abort fib.rs -o fib.wasm) || fail "the Rust core build recipe failed"
  rebuilt="$rebuilt, Rust core"
fi

go_marker=SKIP
if command -v go >/dev/null 2>&1; then
  (cd "$scratch/go" && GOOS=wasip1 GOARCH=wasm go build -o jsonsum.wasm jsonsum.go) \
    || fail "the Go build recipe (GOOS=wasip1 GOARCH=wasm) failed"
  rebuilt="$rebuilt, Go"
  go_marker=PASS
fi

expect_probe "$scratch" "$go_marker"
echo "PASS polyglot-rebuilt -> $rebuilt rebuilt from source and loaded"

# --- hosts.cljc: one program, every host on PATH ---------------------------
expected="$(cd "$DEMO" && run_bounded 30 "$ABS_BIN" hosts.cljc 2>&1)" \
  || fail "hosts.cljc failed on cljw:
$expected"
grep -q '^{:host "cljw"' <<<"$expected" || fail "hosts.cljc did not report :host \"cljw\":
$expected"
hosts="cljw"

cljrs_bin="${CLJRS_BIN:-$(command -v cljrs || true)}"
if [ -n "$cljrs_bin" ] && [ -x "$cljrs_bin" ]; then
  got="$(cd "$DEMO" && run_bounded 60 "$cljrs_bin" run hosts.cljc 2>&1)" || fail "hosts.cljc failed on cljrs:
$got"
  [ "${got/:host \"cljrs\"/:host \"cljw\"}" = "$expected" ] || fail "cljrs disagrees with cljw on hosts.cljc:
cljw:  $expected
cljrs: $got"
  hosts="$hosts, cljrs"
fi

if command -v clojure >/dev/null 2>&1 && [ -z "${CLJW_POLYGLOT_SKIP_JVM:-}" ]; then
  got="$(cd "$DEMO" && run_bounded 120 clojure -M hosts.cljc 2>&1)" || fail "hosts.cljc failed on JVM Clojure:
$got"
  [ "${got/:host \"jvm\"/:host \"cljw\"}" = "$expected" ] || fail "JVM Clojure disagrees with cljw on hosts.cljc:
cljw: $expected
jvm:  $got"
  hosts="$hosts, jvm"
fi
echo "PASS polyglot-hosts -> hosts.cljc agrees on: $hosts"

echo
echo "Phase 16 / polyglot demo: committed guests, rebuilt guests, and every host on PATH agree."
