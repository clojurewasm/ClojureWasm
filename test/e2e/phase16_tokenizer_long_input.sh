#!/usr/bin/env bash
# test/e2e/phase16_tokenizer_long_input.sh — untrusted-input DoS guard for the
# tokenizer (found by the 2026-06-09 reader-DoS audit). A single source LINE
# longer than 65535 columns overflowed `Tokenizer.column` (u16 `+= 1`), and a
# single TOKEN longer than 65535 chars overflowed `Token.len` (u16 `@intCast`) —
# both PANIC in the shipped ReleaseSafe build (whole-process crash on e.g. a
# minified one-line JSON/EDN payload). cljw must read large input cleanly, never
# integer-overflow-panic. Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

# (1) A long single LINE (~80k columns > 65535) must not panic. Use a long
# COMMENT so the tokenizer advances its column past 65535 without building a huge
# literal (which would hit a separate VM operand-stack limit, not the tokenizer).
# (`println` because a bare file run is script mode — it does not echo results.)
python3 -c "print(';; ' + 'x'*80000); print('(println 42)')" > /tmp/cljw_longline.$$.clj
trap 'rm -f /tmp/cljw_longline.$$.clj /tmp/cljw_longtok.$$.clj' EXIT
out=$("$BIN" /tmp/cljw_longline.$$.clj 2>&1) || true
echo "$out" | grep -qiE "panic|integer overflow" && fail "long line PANICKED (tokenizer column u16 overflow): $out"
[[ "$out" == "42" ]] || fail "long line wrong/failed result (expected 42): $out"
echo "PASS tok-long-line-no-panic -> $out"

# (2) A long single TOKEN (string literal > 65535 chars) must not panic and must
# not silently truncate (Token.len must hold the full length).
python3 -c "n=70000; print('(println (count ' + '\"' + 'a'*n + '\"' + '))')" > /tmp/cljw_longtok.$$.clj
out=$("$BIN" /tmp/cljw_longtok.$$.clj 2>&1) || true
echo "$out" | grep -qiE "panic|integer overflow" && fail "long token PANICKED (Token.len u16 overflow): $out"
[[ "$out" == "70000" ]] || fail "long token wrong/truncated count (expected 70000): $out"
echo "PASS tok-long-token-no-panic -> $out"

echo "OK — phase16_tokenizer_long_input (2 cases) green"
