#!/usr/bin/env bash
# test/e2e/phase14_cljw_build.sh
#
# Phase 14 §9.16 row 14.11 — D-100(b) `cljw build`. Compile a Clojure
# source to a serialized bytecode payload embedded in a copy of the cljw
# binary (Deno-style "CLJC" trailer, ADR-0034 + amendment 1/2), then run
# the produced self-contained binary. Exercises:
#   - fn_val constant serialization (the `greet` fn — ADR-0034 am2)
#   - the interleaved per-chunk startup run (chunk 2 calls `greet` def'd
#     in chunk 1 — EnvelopeIterator)
#   - the `"CLJC"` artifact trailer (frame/extract)
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/app.clj" <<'CLJ'
(def greet (fn* [name] (str "hello, " name)))
(println (greet "world"))
CLJ

OUT="$TMP/app"

# Build: compile app.clj into a self-contained binary at $OUT.
"$BIN" build "$TMP/app.clj" -o "$OUT" >/dev/null

# (1) The artifact ends with the "CLJC" trailer magic.
footer=$(tail -c 4 "$OUT")
[[ "$footer" == "CLJC" ]] || fail "trailer_magic: tail -c4 = '$footer', want 'CLJC'"
echo "PASS trailer_magic -> CLJC"

# (2) The produced binary is executable and runs its embedded payload.
[[ -x "$OUT" ]] || fail "executable_bit: $OUT is not executable"
got=$("$OUT")
[[ "$got" == "hello, world" ]] || fail "embedded_run: got '$got', want 'hello, world'"
echo "PASS embedded_run -> hello, world"

# (3) The plain cljw binary (no trailer) is unaffected — still a REPL/-e
#     driver, not an embedded-payload runner.
plain=$("$BIN" -e '(+ 1 2)')
[[ "$plain" == "3" ]] || fail "plain_unaffected: got '$plain', want '3'"
echo "PASS plain_unaffected -> 3"

echo "ALL phase14_cljw_build PASS"
