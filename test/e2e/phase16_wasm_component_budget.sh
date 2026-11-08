#!/usr/bin/env bash
# Caller-controlled component budgets, and the fuel diagnostic on both call
# paths. Uses an existing binary; never builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=${CLJW_BIN:-zig-out/bin/cljw}
[[ -x "$BIN" ]] || { echo "Missing cljw binary: $BIN" >&2; exit 2; }
# An outer bound makes a broken fuel implementation fail without hanging CI.
# timeout -> gtimeout -> unbounded: hosted macOS runners ship neither GNU
# timeout nor coreutils gtimeout (same idiom as phase16_gc_torture.sh).
run_bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; else "$@"; fi; }
run_bounded 20 "$BIN" - <<'CLJ'
(def path "test/e2e/fixtures/wasm/spin_component.wasm")
(def core-path "test/e2e/fixtures/wasm/spin.wasm")
(defn check [label value]
  (when-not value (throw (ex-info (str "FAIL " label) {})))
  (println "PASS" label))
(defn rejected? [opts]
  (try (wasm/load-component path opts) false (catch Throwable _ true)))
;; A budget kill must name the budget: "trapped" would read as a guest bug.
(defn fuel-error? [f]
  (try (f) false
       (catch Throwable t (boolean (re-find #"fuel budget" (ex-message t))))))
(defn throws? [f] (try (f) false (catch Throwable _ true)))

(check "default-compatible" (= 42 (wasm/component-call (wasm/load-component path) "ok")))
(def h (wasm/load-component path {:fuel 1000 :max-memory-pages 2}))
(check "limited-control" (= 42 (wasm/component-call h "ok")))
(check "fuel-terminates-spin-and-says-so" (fuel-error? #(wasm/component-call h "spin")))
(check "exhausted-instance-stays-exhausted" (fuel-error? #(wasm/component-call h "ok")))
(def hb (wasm/load-component path {:fuel 1000 :max-memory-pages 2}))
(check "fresh-instance-control" (= 10 (wasm/component-call hb "burn" 10)))
(check "fuel-cumulative-across-calls"
       (loop [remaining 200]
         (if (zero? remaining)
           false
           (if (fuel-error? #(wasm/component-call hb "burn" 10))
             true
             (recur (dec remaining))))))
(check "cumulative-exhaustion-persists" (fuel-error? #(wasm/component-call hb "ok")))
(def hm (wasm/load-component path {:fuel 1000 :max-memory-pages 2}))
(check "grow-within-cap" (= 1 (wasm/component-call hm "grow" 1)))
(check "grow-refused-at-cap" (= -1 (wasm/component-call hm "grow" 1)))
(check "invalid-options" (rejected? 1))
(check "invalid-fuel" (rejected? {:fuel "1000"}))
(check "invalid-memory" (rejected? {:max-memory-pages "2"}))
(check "unsupported-engine" (rejected? {:engine :jit}))
(check "unsupported-deadline" (rejected? {:timeout-ms 1}))
(check "explicit-unmetered" (= 42 (wasm/component-call (wasm/load-component path {:fuel 0 :max-memory-pages 2}) "ok")))

;; The core-module path (wasm/load + wasm/call) shares the diagnostic, and its
;; message names the export.
(def m (wasm/load core-path {:fuel 1000}))
(check "module-control" (= 42 (wasm/call m "ok")))
(check "module-fuel-names-export"
       (try (wasm/call m "spin") false
            (catch Throwable t (boolean (re-find #"'spin' exhausted the module's fuel budget" (ex-message t))))))
(check "module-genuine-trap-is-still-a-trap"
       (try (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom") false
            (catch Throwable t (and (not (re-find #"fuel" (ex-message t)))
                                    (boolean (re-find #"trapped" (ex-message t)))))))
(println "component budgets: passed")
CLJ
