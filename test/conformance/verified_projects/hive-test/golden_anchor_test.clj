(ns golden-anchor-test
  "Cover the anchor itself, not just the laws that use it.

   Every case here runs against an in-memory `Filesystem` and a map-backed
   `Environment`, so the anchoring rule is checked with no disk, no working
   directory and no redef. That is the whole point of the port split in
   `golden-anchor`: the bug this adapter fixes lived in the ORDERING of
   candidate directories, and ordering is now a pure function.

   Run: cljw -M:anchor-test   (or clojure -M:anchor-test)"
  (:require [clojure.test :as test :refer [deftest is testing]]
            [golden-anchor :as a]
            [hive-test.golden.store :as store]
            [hive-test.golden.root :as root]
            [hive-test.golden :as golden]))

(def fixture-dir "/repo/test/conformance/verified_projects/hive-test")

(defn env
  "Environment over a plain map."
  [m]
  (reify a/Environment
    (-property [_ k] (get m k))
    (-variable [_ k] (get m k))))

(def warm-session
  "A warm session rooted at the repository, with the fixture NOT on the
   classpath. This is the shape that used to anchor at the repo root."
  (env {"user.dir" "/repo" "java.class.path" "/repo/src" "path.separator" ":"}))

(def launched-from-fixture
  (env {"user.dir" fixture-dir "java.class.path" "." "path.separator" ":"}))

(def complete-tree
  {"/repo" #{"src"}
   "/repo/src" #{}
   fixture-dir (into #{"laws.clj" "deps.edn"} a/golden-files)})

(deftest ancestor-paths-walks-up-to-root
  (is (= ["/repo/a/b" "/repo/a" "/repo" "/"] (a/ancestor-paths "/repo/a/b")))
  (testing "a trailing slash does not produce a duplicate step"
    (is (= ["/repo/a" "/repo" "/"] (a/ancestor-paths "/repo/a/"))))
  (testing "blank input yields nothing rather than a bogus root"
    (is (nil? (a/ancestor-paths "")))))

(deftest split-classpath-drops-blanks
  (is (= ["a" "b" "c"] (a/split-classpath "a:b::c" ":")))
  (is (= [] (a/split-classpath "" ":")))
  (testing "the separator is quoted, so a regex metacharacter is literal"
    (is (= ["a" "b"] (a/split-classpath "a.b" ".")))))

(deftest candidate-order-is-the-anchoring-rule
  (let [reading {:cwd "/repo" :class-path "/repo/src" :path-separator ":"
                 :explicit-root nil}]
    (testing "classpath is searched before the working-directory walk-up"
      (is (= ["/repo/src" "/repo" "/" (str "/repo/" "test/conformance/verified_projects/hive-test")]
             (a/candidate-order reading))))
    (testing "an explicit root outranks everything"
      (is (= "/elsewhere"
             (first (a/candidate-order (assoc reading :explicit-root "/elsewhere"))))))
    (testing "a blank explicit root is ignored rather than tried"
      (is (= "/repo/src"
             (first (a/candidate-order (assoc reading :explicit-root "  "))))))))

(deftest missing-names-reports-only-absentees
  (is (= [] (a/missing-names #{"a" "b"} ["a" "b"])))
  (is (= ["b"] (a/missing-names #{"a"} ["a" "b"]))))

(deftest resolves-the-fixture-from-a-warm-repo-root-session
  (testing "the defect this adapter exists for: a session rooted at the repo
            must still anchor at the fixture, not at the repo"
    (is (= fixture-dir
           (a/resolve-root (a/memory-filesystem complete-tree) warm-session)))))

(deftest resolves-the-fixture-when-launched-from-it
  (is (= fixture-dir
         (a/resolve-root (a/memory-filesystem complete-tree) launched-from-fixture))))

(deftest an-explicit-root-wins-over-discovery
  (let [other "/somewhere/else"
        tree (assoc complete-tree other (into #{"laws.clj" "deps.edn"} a/golden-files))]
    (is (= other
           (a/resolve-root (a/memory-filesystem tree)
                           (env {"user.dir" "/repo"
                                 "java.class.path" "/repo/src"
                                 "path.separator" ":"
                                 "CLJW_GOLDEN_ROOT" other}))))))

(deftest no-fixture-anywhere-fails-and-names-what-was-searched
  (let [e (is (thrown-with-msg?
               clojure.lang.ExceptionInfo #"no candidate directory carries the fixture markers"
               (a/resolve-root (a/memory-filesystem {"/repo" #{}}) warm-session)))]
    (testing "the failure carries the search trail, so it is diagnosable"
      (is (seq (:tried (ex-data e))))
      (is (= a/markers (:markers (ex-data e)))))))

(deftest a-directory-missing-one-identity-marker-is-not-the-fixture
  (let [tree (assoc complete-tree fixture-dir #{"deps.edn"})]
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"no candidate directory"
                          (a/resolve-root (a/memory-filesystem tree) warm-session)))))

(deftest an-incomplete-corpus-fails-in-the-right-directory-and-names-the-files
  (testing "identity and corpus are separate faults: this one means you are in
            the RIGHT directory with a reviewed file gone, so it must name it
            rather than blame the working directory"
    (let [tree (assoc complete-tree fixture-dir #{"laws.clj" "deps.edn" "subvec.edn"})
          fs (a/memory-filesystem tree)
          root (a/resolve-root fs warm-session)
          e (is (thrown-with-msg? clojure.lang.ExceptionInfo
                                  #"reviewed golden corpus is incomplete"
                                  (a/assert-corpus! fs root)))]
      (is (= fixture-dir root))
      (is (= ["lazy-seqable.edn" "split-lines.edn" "replace.edn"]
             (:missing (ex-data e)))))))

(deftest a-complete-corpus-passes-through-its-root
  (let [fs (a/memory-filesystem complete-tree)]
    (is (= fixture-dir (a/assert-corpus! fs fixture-dir)))
    (is (= [] (a/missing-goldens fs fixture-dir)))))

(deftest guarded-store-refuses-to-invent-a-golden
  (let [mem (store/memory-store {"present.edn" {:a 1}})
        guarded (a/guarded-store mem false)]
    (testing "reads and existence checks delegate untouched"
      (is (= {:a 1} (store/-read guarded "present.edn")))
      (is (true? (store/-exists? guarded "present.edn"))))
    (testing "an absent golden is refused, and the store is left alone"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"refusing to write the golden"
                            (store/-write! guarded "new.edn" {:b 2})))
      (is (false? (store/-exists? mem "new.edn"))))))

(deftest guarded-store-allows-a-deliberate-capture-and-verifies-the-read-back
  (let [mem (store/memory-store {})
        guarded (a/guarded-store mem true)]
    (is (= {:b 2} (store/-write! guarded "new.edn" {:b 2})))
    (is (= {:b 2} (store/-read mem "new.edn")))))

(deftest guarded-store-catches-a-golden-that-does-not-survive-its-round-trip
  (testing "a capture that reads back as something else is reported at capture
            time rather than as a mismatch on some later run"
    (let [lossy (reify store/GoldenStore
                  (-read [_ _] {:different true})
                  (-write! [_ _ v] v)
                  (-exists? [_ _] false))]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"did not survive a read back"
                            (store/-write! (a/guarded-store lossy true) "x.edn" {:a 1}))))))

(deftest update-allowed-reads-the-same-switch-hive-test-does
  (is (true? (a/update-allowed? (env {"UPDATE_GOLDEN" "true"}))))
  (is (false? (a/update-allowed? (env {"UPDATE_GOLDEN" "1"}))))
  (is (false? (a/update-allowed? (env {})))))

(deftest install-resolves-and-asserts-in-one-call
  (testing "a runner cannot anchor without also checking the corpus"
    (let [{:keys [root bindings]} (a/install (a/memory-filesystem complete-tree) warm-session)]
      (is (= fixture-dir root))
      (is (contains? bindings #'hive-test.golden/*project-root*))
      (is (contains? bindings #'hive-test.golden/*store*)))
    (let [tree (assoc complete-tree fixture-dir #{"laws.clj" "deps.edn"})]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"corpus is incomplete"
                            (a/install (a/memory-filesystem tree) warm-session))))))

(deftest fixture-project-root-never-returns-nil
  (testing "the classpath walk-up returning nil is exactly what let a relative
            golden path through; this strategy cannot"
    (let [pr (a/fixture-project-root fixture-dir)]
      (is (some? (hive-test.golden.root/-root-for pr 'any.ns)))
      (is (= fixture-dir (.getPath (hive-test.golden.root/-root-for pr 'other.ns)))))))

(defn -main [& _]
  (let [{:keys [test pass fail error] :as result} (test/run-tests 'golden-anchor-test)]
    (assert (pos? test) (pr-str result))
    (assert (and (pos? pass) (zero? fail) (zero? error)) (pr-str result))
    (println "OK golden-anchor:" test "tests," pass "assertions, no disk touched")))
