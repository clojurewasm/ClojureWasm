#!/usr/bin/env bash
# test/e2e/phase14_typed_instance_metadata.sh
#
# D-312 — `with-meta` / `meta` on a typed_instance (defrecord / deftype). A
# defrecord supports metadata NATIVELY (clj records carry a hidden __meta field);
# `with-meta` mints a fresh instance with the meta, equality/hash ignore it, and
# `identical?` is false. A plain deftype without an IObj impl keeps the
# not-an-IObj error (= clj ClassCastException). Layer 2 (e2e CLI).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Record with-meta / meta round-trip + equality + identity ---
cat > "$WORK/rec.clj" <<'EOF'
(defrecord R [a b])
(def r (->R 1 2))
(def rm (with-meta r {:x 9}))
(assert (nil? (meta r)))                ; fresh record: no meta
(assert (= {:x 9} (meta rm)))           ; with-meta stored it
(assert (= r rm))                       ; meta NOT part of value equality
(assert (not (identical? r rm)))        ; distinct object
(assert (and (= 1 (:a rm)) (= 2 (:b rm)))) ; fields intact
(assert (= {:x 9} (meta (assoc rm :a 5))))  ; meta survives assoc (clj-faithful)
(assert (= {:x 9} (meta (update rm :a inc)))) ; ...and update (→ assoc)
(assert (nil? (meta (assoc (->R 1 2) :a 5)))) ; a meta-less record stays nil
(println "OK record-meta")
EOF
got="$("$BIN" "$WORK/rec.clj" 2>&1 | grep '^OK' || true)"
[[ "$got" == "OK record-meta" ]] || fail "record meta: got '$("$BIN" "$WORK/rec.clj" 2>&1 | tail -3)'"
echo "PASS typed_instance_record_meta -> with-meta/meta/= /identical?"

# --- A plain deftype without IObj: with-meta throws (clj ClassCastException) ---
cat > "$WORK/dt.clj" <<'EOF'
(deftype T [a])
(with-meta (->T 1) {:x 1})
EOF
if "$BIN" "$WORK/dt.clj" >/dev/null 2>"$WORK/dt.err"; then
    fail "deftype with-meta unexpectedly succeeded (should throw)"
fi
grep -q "cannot attach metadata" "$WORK/dt.err" || fail "deftype throw msg: got '$(cat "$WORK/dt.err")'"
echo "PASS typed_instance_deftype_no_iobj_throws -> not-an-IObj error"

echo "ALL phase14_typed_instance_metadata PASS"
