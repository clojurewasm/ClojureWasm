#!/usr/bin/env bash
# test/e2e/phase14_deps_run_mode.sh
#
# Convergence Campaign Stage 1.4 / D-309 — deps.edn run modes `-M` / `-X`.
# `-A` resolves a classpath only; `-M`/`-X` (and a bare top-level `-m`)
# additionally RUN something:
#   -M[:alias] [-m ns | file | -e expr]  → clojure.main mini-grammar; alias
#                                            :main-opts ++ user args (APPEND).
#   -X[:alias] [ns/fn] [:k v]            → :exec-fn with the :exec-args map
#                                            merged under CLI :key value (CLI
#                                            wins, values EDN-typed).
# A -main / :exec-fn result is NOT printed (clojure.main contract). Layer 2.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$(pwd)/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

proj="$WORK/proj"; mkdir -p "$proj/src/myapp"
cat > "$proj/src/myapp/core.clj" <<'EOF'
(ns myapp.core)
(defn -main [& args] (println "MAIN" (vec args)))
(defn build [opts] (println "BUILD" (:id opts) (type (:id opts)) (:tag opts)))
EOF
cat > "$proj/deps.edn" <<'EOF'
{:paths ["src"]
 :aliases {:run   {:main-opts ["-m" "myapp.core"]}
           :build {:exec-fn myapp.core/build :exec-args {:id 1 :tag "base"}}}}
EOF

# --- Case 1: bare -m passes trailing args to -main as strings ---
got="$(cd "$proj" && "$BIN" -m myapp.core a b)"
[[ "$got" == 'MAIN [a b]' ]] || fail "bare -m: got '$got'"
echo "PASS run_mode_bare_m -> args reach -main"

# --- Case 2: -M:alias prepends the alias :main-opts, APPENDS user args ---
got="$(cd "$proj" && "$BIN" -M:run extra)"
[[ "$got" == 'MAIN [extra]' ]] || fail "-M:run append: got '$got'"
echo "PASS run_mode_M_alias_append -> alias main-opts + user arg"

# --- Case 3: -X:alias runs :exec-fn with :exec-args; result not printed ---
got="$(cd "$proj" && "$BIN" -X:build)"
[[ "$got" == 'BUILD 1 Long base' ]] || fail "-X:build default: got '$got'"
echo "PASS run_mode_X_exec_args -> exec-fn over alias args"

# --- Case 4: CLI :key value overrides :exec-args, EDN-typed (not a string) ---
got="$(cd "$proj" && "$BIN" -X:build :id 42)"
[[ "$got" == 'BUILD 42 Long base' ]] || fail "-X override EDN type: got '$got'"
echo "PASS run_mode_X_cli_override -> CLI wins, 42 stays Long"

# --- Case 5: trailing ns/fn symbol overrides the alias :exec-fn ---
got="$(cd "$proj" && "$BIN" -X:build myapp.core/build :id 7 :tag "cli")"
[[ "$got" == 'BUILD 7 Long cli' ]] || fail "-X trailing fn: got '$got'"
echo "PASS run_mode_X_fn_override -> trailing symbol exec-fn"

# --- Case 6: -m on a namespace with no -main → clean ex-info message ---
out="$(cd "$proj" && "$BIN" -m myapp.nomain 2>&1 || true)"
printf '%s' "$out" | grep -q "has no -main fn" || {
    # myapp.nomain doesn't exist → require error is also acceptable (clean,
    # not a panic); the no--main path is exercised by a real ns below.
    cat > "$proj/src/myapp/lib.clj" <<'EOF'
(ns myapp.lib)
(defn helper [] :ok)
EOF
    out="$(cd "$proj" && "$BIN" -m myapp.lib 2>&1 || true)"
    printf '%s' "$out" | grep -q "has no -main fn" || fail "-m no -main: got '$out'"
}
echo "PASS run_mode_no_main -> clean 'has no -main fn' error"

# --- Case 7: -X exec-fn return value is NOT printed (only side effects) ---
cat > "$proj/src/myapp/ret.clj" <<'EOF'
(ns myapp.ret)
(defn run [_] 12345)
EOF
got="$(cd "$proj" && "$BIN" -X myapp.ret/run)"
[[ "$got" == '' ]] || fail "-X return not printed: got '$got'"
echo "PASS run_mode_X_no_result_print -> result suppressed"

echo "ALL phase14_deps_run_mode PASS"
