;; Re-requiring a component whose bytes changed at the SAME path
;; (CLJW-REQUIRE-COMPONENT-STALE). The export table is the source of truth for
;; which Vars `require-component` owns in a namespace: exports the new build
;; dropped are unmapped, exports it kept keep their Var identity, and anything
;; the user defined there is never touched.
;;
;; Migrated from test/e2e/phase16_wasm_require_component_reswap.sh plus its
;; fixture, which paid a process spawn to assert by grepping 20 "PASS <name>"
;; markers out of stdout. Nothing here is about the process boundary, so per
;; the cljw-suites direction it belongs in-process, where a failure reports the
;; VALUE that was wrong instead of a missing line of output.
;;
;; TWO THINGS THE SCRIPT COULD DO THAT A SUITE CANNOT, and how they are handled:
;;
;; 1. The script ran top to bottom, so `#'swp/get` was READ after the component
;;    had created the `swp` namespace. A suite COMPILES the whole file first,
;;    when `swp` does not exist yet, so a `#'swp/get` or `(swp/counter 5)`
;;    anywhere in this file would fail the file to load. Every reference to a
;;    component Var is therefore resolved at RUN time via `ns-resolve`.
;; 2. `run-tests` does not promise to run deftests in definition order, and the
;;    generations are a sequence over state on disk and in captured Vars. So
;;    the sequence is ONE deftest with `testing` sections, carrying the old
;;    marker names so the migration stays auditable.
(ns suites.wasm-require-component-reswap-test
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.io :as io]
            [cljw.wasm]))

;; The swap copies BYTES (io/copy File to File): a .wasm is binary, so a
;; spit/slurp round-trip through a String would corrupt it.
(def ^:private counter-bytes "test/e2e/fixtures/wasm/resource_counter.wasm")
(def ^:private echo-bytes "test/e2e/fixtures/wasm/two_export_component.wasm")

(def ^:private swap-dir (str "/tmp/cljw_reswap_suite_" (System/currentTimeMillis)))
(def ^:private swap-path (str swap-dir "/swap_component.wasm"))

(use-fixtures :once
  (fn [run]
    (.mkdirs (io/file swap-dir))
    (try (run)
         (finally
           (.delete (io/file swap-path))
           (.delete (io/file swap-dir))))))

(defn- put-bytes! [src] (io/copy (io/file src) (io/file swap-path)))

(defn- publics [ns-sym] (set (map name (keys (ns-publics ns-sym)))))

(defn- component-publics
  "Names of the Vars in `ns-sym` that require-component interned."
  [ns-sym]
  (set (for [[s v] (ns-publics ns-sym)
             :when (:cljw.wasm/component-export (meta v))]
         (name s))))

(defn- v
  "The Var named `sym` in `ns-sym`, or nil. Resolved at RUN time: see the note
   at the top about why `#'swp/get` cannot appear in this file."
  [ns-sym sym]
  (ns-resolve ns-sym sym))

;; `:refer` interns into the CURRENT ns, and a deftest does not run with *ns*
;; set to the suite, so the refer target is named explicitly and bound. Calling
;; the worker directly (the macro only builds this call) keeps that binding
;; visible instead of hiding it behind quoting.
(def ^:private refer-host 'reswap-refer-host)

(defn- require-component! [opts]
  (binding [*ns* (create-ns refer-host)]
    (cljw.wasm/require-component* swap-path opts)))

(defn- def-in!
  "`def` (not `intern`) inside `ns-sym`: def REPLACES a Var's metadata, which
   is what drops the component tag and makes the name the user's. intern KEEPS
   the metadata, so it would not reproduce the shadowing this asserts.

   `binding`, not `in-ns`: under a test runner *ns* is already thread-bound, so
   `in-ns` mutates the ROOT while `eval` keeps reading the thread-local value,
   and the def silently lands in the calling namespace instead. The script this
   was migrated from could use `in-ns` because it ran at top level, where the
   root binding IS the one in effect."
  [ns-sym sym value]
  (binding [*ns* (create-ns ns-sym)]
    (eval (list 'def sym value))))

(deftest reswap-mirrors-the-new-export-table
  (testing "generation 1: resource_counter interns counter / increment / get"
    (put-bytes! counter-bytes)
    (require-component! {:as 'swp :refer '[increment]})
    (is (= #{"counter" "increment" "get"} (publics 'swp))
        "gen1-exports")
    (is (true? (:cljw.wasm/component-export (meta (v 'swp 'get))))
        "gen1-tagged: an interned Var carries the component-export tag")
    (is (= swap-path (:cljw.wasm/component-path (meta (v 'swp 'get))))
        "gen1-tagged: and the path it came from")
    (is (seq (:arglists (meta (v 'swp 'counter))))
        "gen1-arglists-kept: the WIT signature becomes :arglists")
    (is (some? (v refer-host 'increment))
        "gen1-refer: :refer interned into the current ns"))

  ;; A user def in the component's namespace, and one that SHADOWS an export
  ;; name. From here the shadowing Var is the user's.
  (def-in! 'swp 'user-helper :mine)
  (def-in! 'swp 'increment :shadowed-by-user)

  (testing "a user def over an export name drops the tag"
    (is (nil? (:cljw.wasm/component-export (meta (v 'swp 'increment))))
        "gen1-shadow-untagged"))

  (let [gen1-get-var (v 'swp 'get)
        gen1-handle  ((v 'swp 'counter) 5)]
    (is (= 5 ((v 'swp 'get) gen1-handle)) "gen1-call: counter(5) -> get")

    (testing "generation 2: two_export_component at the SAME path"
      (put-bytes! echo-bytes)
      (require-component! {:as 'swp :refer '[increment]})

      (is (= #{"echo-bool" "echo-s32"} (component-publics 'swp))
          "gen2-component-publics-exact: only the new table's names are owned")
      (is (= #{"echo-bool" "echo-s32" "user-helper" "increment"} (publics 'swp))
          "gen2-user-defs-survive")
      (is (= :shadowed-by-user @(v 'swp 'increment))
          "gen2-user-shadow-value: the user's Var is untouched")
      (is (nil? (v 'swp 'get))
          "gen2-dropped-unmapped: a dropped export stops resolving")
      (is (nil? (v 'swp 'counter))
          "gen2-dropped-unmapped: both of them")
      (is (nil? (v refer-host 'increment))
          "gen2-refer-dropped-unmapped: the :refer side is retired too")
      (is (= 7 ((v 'swp 'echo-s32) 7)) "gen2-new-exports-call: echo-s32")
      (is (true? ((v 'swp 'echo-bool) true)) "gen2-new-exports-call: echo-bool"))

    (testing "a Var captured before the swap throws instead of reaching the old instance"
      (let [r (try (gen1-get-var gen1-handle) :NOT-CAUGHT
                   (catch Exception e (ex-message e)))]
        (is (string? r)
            (str "gen2-orphan-var-throws: expected a catchable error, got " (pr-str r)))
        (is (and (string? r) (re-find #"no longer exports `get`" r))
            (str "gen2-orphan-var-throws: message must name the export, got " (pr-str r))))))

  (testing "generation 3: back to resource_counter, over the name the user took"
    ;; Requiring into a namespace is a request for the export table's names, so
    ;; an export whose name the user had taken is interned over it, exactly as
    ;; a first require into that namespace would.
    (put-bytes! counter-bytes)
    (require-component! {:as 'swp})
    (is (= #{"counter" "increment" "get"} (component-publics 'swp))
        "gen3-component-publics-exact")
    (is (= :mine @(v 'swp 'user-helper))
        "gen3-user-helper-survives")
    (is (nil? (v 'swp 'echo-s32))
        "gen3-echo-unmapped"))

  (testing "generation 4: the same bytes again keeps Var IDENTITY"
    (let [gen3-get-var (v 'swp 'get)]
      (require-component! {:as 'swp})
      (is (identical? gen3-get-var (v 'swp 'get))
          "gen4-var-identity-kept: a kept export is rebound, not re-interned")
      (is (= 3 ((v 'swp 'get) ((v 'swp 'counter) 3)))
          "gen4-call-through-kept-var"))))

(deftest ns-directive-routes-through-the-same-worker
  ;; The `ns` special form desugars a string libspec to require-component*, so
  ;; the retire path must hold there too and not only through the macro. This
  ;; deftest puts its own bytes, so it does not depend on running after the
  ;; sequence above.
  (let [prev (ns-name *ns*)]
    (try
      (put-bytes! counter-bytes)
      (eval (list 'ns 'reswap-app (list :require [swap-path :as 'rsw])))
      (in-ns prev)
      (is (= #{"counter" "get" "increment"} (component-publics 'rsw))
          "ns-directive-gen1")

      (put-bytes! echo-bytes)
      (eval (list 'ns 'reswap-app (list :require [swap-path :as 'rsw])))
      (in-ns prev)
      (is (= #{"echo-bool" "echo-s32"} (component-publics 'rsw))
          "ns-directive-gen2: the directive path retires too")
      (finally (in-ns prev)))))
