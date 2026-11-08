;; System properties used by portable code. Environment-specific TMPDIR process
;; cases stay in test/e2e/phase15_system_property.sh (they require a fresh process).
(ns suites.system-properties-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest standard-properties
  (testing "known host properties"
    (is (= "/" (System/getProperty "file.separator")))
    (is (= ":" (System/getProperty "path.separator")))
    (is (= "\n" (System/getProperty "line.separator")))
    (is (string? (System/getProperty "os.name")))
    (is (= (System/getenv "HOME") (System/getProperty "user.home")))
    (is (string? (System/getProperty "user.dir")))
    (is (= "/tmp" (System/getProperty "java.io.tmpdir"))
        "JVM parity: java.io.tmpdir ignores $TMPDIR"))
  (testing "getProperties reflects getProperty, including dynamic and overridden values"
    (doseq [key ["java.io.tmpdir" "user.home" "user.dir" "os.name"
                 "line.separator" "file.separator"]]
      (is (= (System/getProperty key) (get (System/getProperties) key)) key))
    (let [old (System/setProperty "java.io.tmpdir" "/cljw-test-override")]
      (try
        (is (= "/cljw-test-override" (System/getProperty "java.io.tmpdir")))
        (is (= "/cljw-test-override" (get (System/getProperties) "java.io.tmpdir")))
        (finally
          (if old
            (System/setProperty "java.io.tmpdir" old)
            (System/clearProperty "java.io.tmpdir")))))))
