#!/usr/bin/env bash
# clojure.uuid backfill (D-273). In ClojureWasm the `#uuid` reader literal and the
# `#uuid "…"` print form are BUILT IN (the reader's default data-readers + the UUID
# print path), so this namespace is a thin require-compatibility shim: a real library
# that `(require 'clojure.uuid)` for its side-effects must load. It exposes the
# `default-uuid-reader` data-reader fn (faithful to upstream) over java.util.UUID.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# (require 'clojure.uuid) must succeed (currently fails — missing ns), and the
# #uuid reader + UUID print stay clj-faithful after it loads.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.uuid)
(prn [(= #uuid "12345678-1234-1234-1234-123456789abc"
         (clojure.uuid/default-uuid-reader "12345678-1234-1234-1234-123456789abc"))
      (pr-str #uuid "12345678-1234-1234-1234-123456789abc")])
EOF
)
assert_eq 'uuid_require_and_reader' "$got" '[true "#uuid \"12345678-1234-1234-1234-123456789abc\""]'

echo
echo "clojure.uuid backfill (D-273) e2e: all green."
