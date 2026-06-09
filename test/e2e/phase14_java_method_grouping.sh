#!/usr/bin/env bash
# test/e2e/phase14_java_method_grouping.sh
#
# D-372 / ADR-0102 am2 / AD-NNN — java.util.Map/Iterable methods GROUPED under a
# clojure.lang.* deftype-supertype section. clj's IPersistentMap/Set/Vector EXTEND
# Iterable/Map/Collection, so a library may place `iterator`/`entrySet`/`keySet`/…
# under its `clojure.lang.IPersistentMap` section (flatland.ordered.map does).
# cljw has no java dispatch (ADR-0059/0103), so these are ACCEPTED-AND-DROPPED
# (load-level, like a whole host_inert java section) instead of feature_not_supported.
# Validates: the deftype LOADS; the real clojure.lang methods still dispatch; a
# DROPPED method is DECLINED (method-not-found) — NOT a silent value (the pin that
# keeps the drop honest, not a permanent-no-op).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1: a deftype with java.util methods grouped under IPersistentMap LOADS,
#             and the real clojure.lang methods (valAt/assoc/count) still dispatch ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype OM [m]
  clojure.lang.IPersistentMap
  (valAt [this k] (get m k))
  (assoc [this k v] (OM. (assoc m k v)))
  (count [this] (count m))
  (seq [this] (seq m))
  (without [this k] (OM. (dissoc m k)))
  (cons [this x] this)
  (empty [this] (OM. {}))
  (iterator [this] (throw (ex-info "jvm-only" {})))
  (entrySet [this] (throw (ex-info "jvm-only" {})))
  (keySet [this] (throw (ex-info "jvm-only" {})))
  (values [this] (throw (ex-info "jvm-only" {}))))
(let [x (.assoc (OM. {}) :a 1)]
  (prn [(.valAt x :a) (.count x)]))
EOF
) || fail "case1: non-zero exit ($got)"
[ "$got" = "[1 1]" ] || fail "case1: expected [1 1], got '$got'"

# --- Case 2 (the pin): a DROPPED java method is DECLINED, not silently answered ---
out=$("$BIN" - <<'EOF' 2>&1 || true
(deftype OM2 [m]
  clojure.lang.IPersistentMap
  (valAt [this k] (get m k))
  (iterator [this] :should-never-run))
(.iterator (OM2. {}))
EOF
)
echo "$out" | grep -qiE "iterator|member|no implementation|not.*found|unsupported" \
    || fail "case2: expected a method-not-found error for the dropped .iterator (got a value?), got '$out'"
echo "$out" | grep -q "should-never-run" \
    && fail "case2: the dropped iterator body RAN (silent no-op leak) — got '$out'"

echo "PASS phase14_java_method_grouping (2 cases)"
