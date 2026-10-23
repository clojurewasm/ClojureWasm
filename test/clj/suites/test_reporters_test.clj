;; clojure.test itself and its reporters, plus the other bundled REPL/debug
;; nses (D-227/D-273/D-463/D-475/D-502/D-513/D-563b, ADR-0140/0156).
;;
;; Migrated from the phase15 e2e scripts clojure_test, clojure_test_output,
;; clojure_test_tap, test_junit, spec, repl_discovery, tap and
;; clojure_stacktrace. A case that defines deftests and calls run-tests is a
;; NESTED run inside this suite's own run, so `nested-run` isolates the
;; clojure.test dynamic state (report counters, testing vars/contexts,
;; *test-out*) and evaluates the program in a fresh p15 namespace. The program
;; text in a case is what the script fed to `cljw -`; only the namespace names
;; differ (unique across the shared suite image).
(ns suites.test-reporters-test
  (:require [clojure.test :as t :refer [deftest is testing]]
            [clojure.string :as str]
            [clojure.spec.alpha :as s]
            [clojure.repl]
            [clojure.set]
            [clojure.stacktrace]))

(def ^:private scratch-seq (atom 0))

(defn- fresh-ns-name [] (symbol (str "p15.rep" (swap! scratch-seq inc))))

(defn- nested-run
  "Evaluate `src` (which may contain {{ns}}, replaced by a fresh ns name) as a
  nested clojure.test program. Returns {:value v :out captured-stdout}."
  [src]
  (let [n (fresh-ns-name)
        src (str/replace src "{{ns}}" (str n))
        w (java.io.StringWriter.)]
    (binding [t/*report-counters* nil
              t/*testing-vars* (list)
              t/*testing-contexts* (list)
              t/*test-out* w
              *ns* (create-ns n)]
      (refer 'clojure.core)
      (let [out (with-out-str (binding [t/*test-out* *out*]
                                (def ^:private last-value (load-string src))))]
        {:value last-value :out out}))))

(defn- counts [src]
  (let [{s :value} (nested-run src)] [(:test s) (:pass s) (:fail s) (:error s)]))

(defn- out-lines [src] (set (str/split-lines (:out (nested-run src)))))

(deftest p15-clojure-test-counts
  (let [hdr "(ns {{ns}} (:require [clojure.test :refer [deftest is are testing run-tests]])) "]
    (testing "phase15_clojure_test"
      (is (= [1 3 0 0] (counts (str hdr "(deftest a (is (= 1 1)) (is (pos? 3)) (is (not (nil? [])))) (run-tests '{{ns}})"))) "all-pass")
      (is (= [1 1 1 0] (counts (str hdr "(deftest a (is (= 1 1)) (is (= 1 2))) (run-tests '{{ns}})"))) "one-fail")
      (is (= [1 0 0 1] (counts (str hdr "(deftest a (is (throw (ex-info \"x\" {})))) (run-tests '{{ns}})"))) "error")
      (is (= [1 1 0 0] (counts (str hdr "(deftest a (is (thrown? Throwable (throw (ex-info \"x\" {}))))) (run-tests '{{ns}})"))) "thrown")
      (is (= [1 3 0 0] (counts (str hdr "(deftest a (are [x y] (= x y) 1 1 2 2 3 3)) (run-tests '{{ns}})"))) "are")
      (is (= [2 3 0 0] (counts (str hdr "(deftest a (is (= 1 1))) (deftest b (is (= 2 2)) (is (= 3 3))) (run-tests)"))) "multi-deftest")
      (is (= [1 2 0 0] (counts (str hdr "(deftest a (testing \"ctx\" (is (= 1 1)) (is (= 2 2)))) (run-tests '{{ns}})"))) "testing"))))

(deftest p15-clojure-test-output
  (let [hdr "(ns {{ns}} (:require [clojure.test :refer [deftest is testing run-tests]])) "]
    (testing "phase15_clojure_test_output A (= fail)"
      (let [{:keys [out]} (nested-run (str hdr "(deftest eqfail (is (= 1 2))) (run-tests '{{ns}})"))
            ls (set (str/split-lines out))]
        (is (some #(re-matches #"Testing p15\.rep\d+" %) ls) "A-testing")
        (is (str/includes? out "FAIL in (eqfail) (") "A-fail-in (D-563b suffix)")
        (is (ls "expected: (= 1 2)") "A-expected")
        (is (ls "  actual: (not (= 1 2))") "A-actual")
        (is (ls "Ran 1 tests containing 1 assertions.") "A-ran")
        (is (ls "1 failures, 0 errors.") "A-summary")))
    (testing "B predicate fail"
      (is ((out-lines (str hdr "(deftest pf (is (pos? -1))) (run-tests '{{ns}})")) "  actual: (not (pos? -1))") "B-actual"))
    (testing "C testing context"
      (is ((out-lines (str hdr "(deftest cf (testing \"outer\" (testing \"inner\" (is (= :a :b))))) (run-tests '{{ns}})")) "outer inner") "C-context"))
    (testing "E/F *test-out* rebinding"
      (is (some? (resolve 'clojure.test/*test-out*)) "E-resolvable")
      (let [{:keys [value]} (nested-run (str hdr "(deftest f (is (= 1 2))) (with-out-str (binding [clojure.test/*test-out* *out*] (run-tests '{{ns}})))"))]
        (is (str/includes? value "FAIL in (f) (") "F-captured-fail")))))

(deftest p15-clojure-test-tap
  (testing "phase15_clojure_test_tap"
    (let [{:keys [out]} (nested-run "(require '[clojure.test :as t] '[clojure.test.tap :as tap])
(t/deftest pass-t (t/is (= 1 1)))
(t/deftest fail-t (t/is (= 1 2)))
(tap/with-tap-output (t/run-tests '{{ns}}))")
          ;; normalise the fresh ns name and the source label (`<stdin>` in the
          ;; script, NO_SOURCE_PATH under load-string; the ` (file:line)` suffix
          ;; itself is the D-563b behaviour under test)
          norm (-> out
                   (str/replace #"p15\.rep\d+" "NS")
                   (str/replace #"\((?:NO_SOURCE_PATH|<stdin>):\d+\)" "(SRC)"))]
      (is (= (str/join "\n" ["# {:type :begin-test-ns, :ns NS}"
                             "# {:type :begin-test-var, :var #'NS/pass-t}"
                             "ok (pass-t) (SRC)"
                             "# expected:(= 1 1)"
                             "#   actual:(= 1 1)"
                             "# {:type :end-test-var, :var #'NS/pass-t}"
                             "# {:type :begin-test-var, :var #'NS/fail-t}"
                             "not ok (fail-t) (SRC)"
                             "# expected:(= 1 2)"
                             "#   actual:(not (= 1 2))"
                             "# {:type :end-test-var, :var #'NS/fail-t}"
                             "# {:type :end-test-ns, :ns NS}"
                             "1..2"])
             (str/trim norm))
          "tap_output (also clojure_test_output D-pass-actual)"))))

(deftest p15-test-junit
  (testing "phase15_test_junit"
    (let [{:keys [out]} (nested-run "(require '[clojure.test :as t] '[clojure.test.junit :as ju])
(t/deftest a-pass (t/is (= 1 1)))
(t/deftest a-fail (t/is (= 1 2)))
(ju/with-junit-output (t/run-tests '{{ns}}))")
          out (str/replace out #"p15\.rep\d+" "NS")]
      (doseq [needle ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                      "<testsuites>"
                      "<testcase name=\"a-pass\" classname=\"NS\">"
                      "<testcase name=\"a-fail\" classname=\"NS\">"
                      "<failure>expected: (= 1 2)"
                      "</testsuite>"
                      "</testsuites>"]]
        (is (str/includes? out needle) needle))
      (is (re-find #"<testsuite name=\"rep\d+\" package=\"p15\">" out)
          "testsuite element names the ns")))
  (testing "begin/end-test-var fire for a custom reporter"
    ;; report is ^:dynamic (D-273), so a custom reporter is a binding, which
    ;; leaves the shared multimethod untouched.
    (let [evs (atom [])]
      (binding [t/report (fn [m] (when (#{:begin-test-var :end-test-var} (:type m))
                                   (swap! evs conj ({:begin-test-var :begin :end-test-var :end} (:type m)))))]
        (nested-run "(clojure.test/deftest z (clojure.test/is true)) (clojure.test/run-tests '{{ns}})"))
      (is (= [:begin :end] @evs)))))

(s/def ::p15-age (s/and int? pos?))
(s/def ::p15-r int?)
(defmulti p15-shp :t)
(defmethod p15-shp :c [_] (s/keys :req-un [::p15-r]))
(s/def ::p15-shp (s/multi-spec p15-shp :t))

(deftest p15-spec
  (testing "phase15_spec regex ops"
    (is (true? (s/valid? (s/and int? pos?) 5)) "load_valid")
    (is (= {:a 1 :b "x"} (s/conform (s/cat :a int? :b string?) [1 "x"])) "cat")
    (is (= [1 2 3] (s/conform (s/* int?) [1 2 3])) "star")
    (is (= [1 2] (s/conform (s/+ int?) [1 2])) "plus")
    (is (nil? (s/conform (s/? int?) [])) "opt")
    (is (= [:s "x"] (s/conform (s/alt :i int? :s string?) ["x"])) "alt")
    (is (= [1 2] (s/conform (s/& (s/* int?) (fn [v] (even? (count v)))) [1 2])) "amp")
    (is (= {:a [:x 1]} (s/conform (s/cat :a (s/alt :x int? :y (s/cat :p int? :q int?))) [1])) "nestreg"))
  (testing "collection / scalar specs"
    (is (= [1 2 3] (s/conform (s/coll-of int?) [1 2 3])) "coll")
    (is (= {:a 1} (s/conform (s/map-of keyword? int?) {:a 1})) "mapof")
    (is (= [1 "x"] (s/conform (s/tuple int? string?) [1 "x"])) "tuple")
    (is (nil? (s/conform (s/nilable int?) nil)) "nilable")
    (is (true? (s/valid? (s/keys :req [::p15-age]) {::p15-age 3})) "keys")
    (is (true? (s/valid? ::p15-shp {:t :c :p15-r 2})) "multi"))
  (testing "explain / describe / form"
    (is (= "\"x\" - failed: int?\n" (s/explain-str int? "x")) "explain_named")
    (is (= "-1 - failed: pos?\n" (s/explain-str (s/and int? pos?) -1)) "explain_and")
    (is (= '(and int? pos?) (s/describe (s/and int? pos?))) "describe")
    (is (= "-1 - failed: :clojure.spec.alpha/unknown\n" (s/explain-str (fn [n] (pos? n)) -1)) "explain_anon")
    (is (= '(clojure.spec.alpha/cat :a clojure.core/int?) (s/form (s/cat :a int?))) "form_parity")))

(deftest p15-repl-discovery
  (testing "phase15_repl_discovery"
    (is (= '(difference index intersection join map-invert project rename rename-keys select subset? superset? union)
           (clojure.repl/dir-fn 'clojure.set)) "dir_fn_set")
    (let [out (with-out-str (clojure.repl/dir clojure.set))]
      (is (str/includes? out "difference") "dir_first")
      (is (str/includes? out "union") "dir_last"))
    (is (some #{'clojure.core/reduce-kv} (clojure.repl/apropos "reduce-kv")) "apropos_kv")
    (is (some #{'clojure.core/reductions} (clojure.repl/apropos #"^reductions$")) "apropos_re")
    (is (seq? (clojure.repl/apropos "definitely-no-such-var-xyzzy")) "apropos_empty")))

(deftest p15-tap
  ;; tap> delivers ASYNCHRONOUSLY (an agent queue, D-502), so a value tapped
  ;; earlier may still reach a tap added later: each tap filters on its own
  ;; value instead of taking whatever arrives first.
  (testing "phase15_tap"
    (is (every? some? [(resolve 'tap>) (resolve 'add-tap) (resolve 'remove-tap)]) "resolve")
    (is (true? (tap> 42)) "tap_returns_true")
    (let [p (promise) f (fn [x] (when (= x 99) (deliver p x)))]
      (add-tap f)
      (try (tap> 99)
           (is (= 99 (deref p 2000 :timeout)) "delivers")
           (finally (remove-tap f))))
    (let [p (promise) f (fn [x] (when (= x 7) (deliver p x)))]
      (add-tap f)
      (remove-tap f)
      (tap> 7)
      (is (= :timeout (deref p 300 :timeout)) "remove"))
    (let [p (promise) bad (fn [_] (throw (ex-info "boom" {}))) good (fn [x] (when (= x 5) (deliver p x)))]
      (add-tap bad)
      (add-tap good)
      (try (tap> 5)
           (is (= 5 (deref p 2000 :timeout)) "fault_isolation")
           (finally (remove-tap bad) (remove-tap good))))))

(defn- p15-boom [] (/ 1 0))

(deftest p15-clojure-stacktrace
  (testing "phase15_clojure_stacktrace"
    (is (= "inner" (ex-message (clojure.stacktrace/root-cause (ex-info "outer" {} (ex-info "mid" {} (ex-info "inner" {})))))) "root_cause")
    (is (= "solo" (ex-message (clojure.stacktrace/root-cause (ex-info "solo" {})))) "root_cause_solo")
    (is (= "ExceptionInfo: boom\n{:k 1}" (with-out-str (clojure.stacktrace/print-throwable (ex-info "boom" {:k 1}))))
        "print_throwable")
    ;; AD-029 pin: a never-thrown ex-info keeps the frame-less marker.
    (is (= (str "ExceptionInfo: outer\n{}\n at [no stack trace available]\n"
                "Caused by: ExceptionInfo: inner\n{}\n at [no stack trace available]")
           (str/trim-newline (with-out-str (clojure.stacktrace/print-cause-trace (ex-info "outer" {} (ex-info "inner" {}))))))
        "print_cause_trace")
    (let [e (try (p15-boom) (catch Throwable e e))
          out (with-out-str (clojure.stacktrace/print-stack-trace e))]
      (is (str/includes? out "suites.test-reporters-test/p15-boom") "caught_prints_user_frame")
      (is (not (str/includes? out "[no stack trace available]")) "caught_no_marker")
      (is (some #{"p15-boom"} (map :fn (stack-trace e))) "stack_trace_fn_key")
      (is (some #{"suites.test-reporters-test"} (map :ns (stack-trace e))) "stack_trace_ns_key"))
    (is (= 0 (count (stack-trace (ex-info "x" {})))) "unthrown_no_frames")))
