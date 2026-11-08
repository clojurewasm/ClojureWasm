;; Real Maven source jars: validate hive-spi contracts with malli.
;; This suite runs only when Maven coordinates were selected in deps.edn.
(ns suites.maven-contracts-test
  (:require [clojure.test :refer [deftest is]]))

(deftest maven-source-contracts
  ;; The default gate has no deps.edn. When running from a project with Maven
  ;; coordinates, also assert the actual hive-spi contract shapes.
  (let [malli (try (require 'malli.core) (resolve 'malli.core/validate)
                   (catch Exception _ nil))]
    (is (or (nil? malli) (malli [:map [:a :int]] {:a 1})))
    (when malli
      (require 'hive-spi.native.schema)
      (let [validate (resolve 'hive-spi.native.schema/valid?)
            envelope (var-get (resolve 'hive-spi.native.schema/Envelope))
            library-spec (var-get (resolve 'hive-spi.native.schema/LibrarySpec))]
        (is (validate envelope {:ok true :value 42}))
        (is (validate library-spec {:native/library "demo"
                                    :native/abi :hive-cabi/v1
                                    :native/artifacts {}}))))))
