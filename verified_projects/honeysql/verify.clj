(ns verify
  (:require [honey.sql :as sql]))
;; honeysql formats a Clojure data map into a parameterized SQL vector.
(defn -main [& _]
  (assert (= ["SELECT * FROM foo"] (sql/format {:select :* :from :foo})))
  (assert (= ["SELECT id, name FROM user WHERE id = ?" 1]
             (sql/format {:select [:id :name] :from :user :where [:= :id 1]})))
  (println "OK honeysql — select/from/where format with params"))
