#!/usr/bin/env bash
# test/e2e/phase16_extend_via_metadata.sh — `(defprotocol P :extend-via-metadata
# true …)` dispatches a method via the RECEIVER's metadata when no type-impl
# matches: the fn is stored under the protocol-defining-ns-qualified method SYMBOL
# key (e.g. `user/sized`). clj-oracle-verified contract (D-314):
#   - metadata dispatch works on a plain value with no extend-type;
#   - metadata BEATS an extend-type impl (precedence), gated on the flag;
#   - `satisfies?` IGNORES metadata (→ false for a meta-only extension);
#   - a protocol WITHOUT the flag never consults metadata.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { [[ "$2" == "$3" ]] || fail "$1: got '$2' want '$3'"; echo "PASS $1 -> $3"; }

# 1. meta-only dispatch: a plain map carrying ^{user/sized fn} dispatches via meta.
got=$("$BIN" - <<'EOF' 2>/dev/null || true
(defprotocol Sized :extend-via-metadata true (sized [x]))
(println (sized (with-meta {} {'user/sized (fn [_] 42)})))
EOF
)
assert_eq 'meta_dispatch' "$got" '42'

# 2. satisfies? ignores metadata → false for a meta-only extension (clj parity).
got=$("$BIN" - <<'EOF' 2>/dev/null || true
(defprotocol Sized :extend-via-metadata true (sized [x]))
(println (satisfies? Sized (with-meta {} {'user/sized (fn [_] 42)})))
EOF
)
assert_eq 'satisfies_ignores_meta' "$got" 'false'

# 3. metadata BEATS an extend-type impl (clj precedence), gated on the flag.
got=$("$BIN" - <<'EOF' 2>/dev/null || true
(defprotocol Sized :extend-via-metadata true (sized [x]))
(extend-protocol Sized clojure.lang.IPersistentVector (sized [_] :extend))
(println (sized (with-meta [] {'user/sized (fn [_] :meta-wins)})))
(println (sized []))
EOF
)
assert_eq 'meta_beats_extend' "$got" $':meta-wins\n:extend'

# 4. cache-bypass: metadata is per-VALUE, must not poison the per-TYPE dispatch
# cache. Same-type maps — no-meta uses the extend-type impl, meta uses its fn —
# and they stay independent in either order (ADR-0144 load-bearing pin).
got=$("$BIN" - <<'EOF' 2>/dev/null || true
(defprotocol Sized :extend-via-metadata true (sized [x]))
(extend-protocol Sized clojure.lang.IPersistentMap (sized [_] :extend))
(println (sized {}))
(println (sized (with-meta {} {'user/sized (fn [_] :meta)})))
(println (sized {}))
EOF
)
assert_eq 'cache_bypass' "$got" $':extend\n:meta\n:extend'

# 5. the flag gates it: a protocol WITHOUT :extend-via-metadata never reads meta.
got=$("$BIN" - <<'EOF' 2>&1
(defprotocol Plain (psize [x]))
(try (println (psize (with-meta {} {'user/psize (fn [_] 99)})))
     (catch Throwable _ (println :no-dispatch)))
EOF
)
assert_eq 'flag_gates' "$got" ':no-dispatch'

echo "OK — phase16_extend_via_metadata (5 cases) green"
