;; CSK tests split into small batches to avoid GC crash
(require '[camel-snake-kebab.core :as csk])
(require '[camel-snake-kebab.extras :refer [transform-keys]])

(def pass-count (atom 0))
(def fail-count (atom 0))

(defn check [label expected actual]
  (if (= expected actual)
    (swap! pass-count inc)
    (do
      (swap! fail-count inc)
      (println (str "FAIL: " label))
      (println (str "  expected: " (pr-str expected)))
      (println (str "  actual:   " (pr-str actual))))))

(defn check-throws [label f]
  (try
    (f)
    (swap! fail-count inc)
    (println (str "FAIL: " label " (no exception thrown)"))
    (catch Exception e
      (swap! pass-count inc))))

;; === format-case-test examples ===
(println "=== examples ===")
(check "camelCase symbol" 'fluxCapacitor (csk/->camelCase 'flux-capacitor))
(check "SCREAMING string" "I_AM_CONSTANT" (csk/->SCREAMING_SNAKE_CASE "I am constant"))
(check "kebab keyword" :object-id (csk/->kebab-case :object_id))
(check "HTTP-Header" "X-SSL-Cipher" (csk/->HTTP-Header-Case "x-ssl-cipher"))
(check "kebab-keyword" :object-id (csk/->kebab-case-keyword "object_id"))
(check "snake separator" :s3_key (csk/->snake_case :s3-key :separator \-))

;; === namespaced rejection ===
(println "=== namespaced rejection ===")
(check-throws "ns keyword" #(csk/->PascalCase (keyword "a" "b")))
(check-throws "ns symbol" #(csk/->PascalCase (symbol "a" "b")))

;; === type preserving: string format ===
(println "=== type preserving: string ===")
(doseq [input ["FooBar" "fooBar" "FOO_BAR" "foo_bar" "foo-bar" "Foo_Bar"]]
  (check (str "PascalCase " input) "FooBar" (csk/->PascalCase input))
  (check (str "camelCase " input) "fooBar" (csk/->camelCase input))
  (check (str "SCREAMING " input) "FOO_BAR" (csk/->SCREAMING_SNAKE_CASE input))
  (check (str "snake " input) "foo_bar" (csk/->snake_case input))
  (check (str "kebab " input) "foo-bar" (csk/->kebab-case input))
  (check (str "Camel_Snake " input) "Foo_Bar" (csk/->Camel_Snake_Case input)))

;; === type preserving: keyword format ===
(println "=== type preserving: keyword ===")
(doseq [input [:FooBar :fooBar :FOO_BAR :foo_bar :foo-bar :Foo_Bar]]
  (check (str "PascalCase " input) :FooBar (csk/->PascalCase input))
  (check (str "camelCase " input) :fooBar (csk/->camelCase input))
  (check (str "SCREAMING " input) :FOO_BAR (csk/->SCREAMING_SNAKE_CASE input))
  (check (str "snake " input) :foo_bar (csk/->snake_case input))
  (check (str "kebab " input) :foo-bar (csk/->kebab-case input))
  (check (str "Camel_Snake " input) :Foo_Bar (csk/->Camel_Snake_Case input)))

;; === type preserving: symbol format ===
(println "=== type preserving: symbol ===")
(doseq [input ['FooBar 'fooBar 'FOO_BAR 'foo_bar 'foo-bar 'Foo_Bar]]
  (check (str "PascalCase " input) 'FooBar (csk/->PascalCase input))
  (check (str "camelCase " input) 'fooBar (csk/->camelCase input))
  (check (str "SCREAMING " input) 'FOO_BAR (csk/->SCREAMING_SNAKE_CASE input))
  (check (str "snake " input) 'foo_bar (csk/->snake_case input))
  (check (str "kebab " input) 'foo-bar (csk/->kebab-case input))
  (check (str "Camel_Snake " input) 'Foo_Bar (csk/->Camel_Snake_Case input)))

;; === type converting ===
(println "=== type converting ===")
(check "PascalCaseKeyword" :FooBar (csk/->PascalCaseKeyword 'foo-bar))
(check "SCREAMING_STRING" "FOO_BAR" (csk/->SCREAMING_SNAKE_CASE_STRING :foo-bar))
(check "kebab-symbol" 'foo-bar (csk/->kebab-case-symbol "foo bar"))

;; === blank/separator ===
(println "=== blank/separator ===")
(check "empty" "" (csk/->kebab-case ""))
(check "space" "" (csk/->kebab-case " "))
(check "single sep" "" (csk/->kebab-case "a" :separator \a))
(check "double sep" "" (csk/->kebab-case "aa" :separator \a))

;; === HTTP header ===
(println "=== HTTP header ===")
(check "User-Agent" "User-Agent" (csk/->HTTP-Header-Case "user-agent"))
(check "DNT" "DNT" (csk/->HTTP-Header-Case "dnt"))
(check "Remote-IP" "Remote-IP" (csk/->HTTP-Header-Case "remote-ip"))
(check "TE" "TE" (csk/->HTTP-Header-Case "te"))
(check "UA-CPU" "UA-CPU" (csk/->HTTP-Header-Case "ua-cpu"))
(check "X-SSL-Cipher" "X-SSL-Cipher" (csk/->HTTP-Header-Case "x-ssl-cipher"))
(check "X-WAP-Profile" "X-WAP-Profile" (csk/->HTTP-Header-Case "x-wap-profile"))
(check "X-XSS-Protection" "X-XSS-Protection" (csk/->HTTP-Header-Case "x-xss-protection"))

;; === transform-keys ===
(println "=== transform-keys ===")
(check "nil" nil (transform-keys csk/->kebab-case-keyword nil))
(check "empty map" {} (transform-keys csk/->kebab-case-keyword {}))
(check "empty vec" [] (transform-keys csk/->kebab-case-keyword []))
(check "map transform"
       {:total-books 0 :all-books []}
       (transform-keys csk/->kebab-case-keyword {'total_books 0 "allBooks" []}))
(check "vec of maps"
       [{:the-author "Dr. Seuss" :the-title "Green Eggs and Ham"}]
       (transform-keys csk/->kebab-case-keyword
                       [{'the-Author "Dr. Seuss" "The_Title" "Green Eggs and Ham"}]))
(check "nested"
       {:total-books 1 :all-books [{:the-author "Dr. Seuss" :the-title "Green Eggs and Ham"}]}
       (transform-keys csk/->kebab-case-keyword
                       {'total_books 1 "allBooks" [{'THE_AUTHOR "Dr. Seuss" "the_Title" "Green Eggs and Ham"}]}))

;; === metadata ===
(println "=== metadata ===")
(let [m (with-meta {'total_books 0 "allBooks" []} {:type-name :metadata-type})
      result (transform-keys csk/->kebab-case-keyword m)]
  (check "meta transform" {:total-books 0 :all-books []} result)
  (check "meta preserved" {:type-name :metadata-type} (meta result)))

(let [m (with-meta {} {:type-name :metadata-type})
      result (transform-keys csk/->kebab-case-keyword m)]
  (check "meta empty" {} result)
  (check "meta empty preserved" {:type-name :metadata-type} (meta result)))

(let [m (with-meta [] {:type-name :check})
      result (transform-keys csk/->kebab-case-keyword m)]
  (check "meta vec" [] result)
  (check "meta vec preserved" {:type-name :check} (meta result)))

(let [m (with-meta [{'the-Author "Dr. Seuss" "The_Title" "Green Eggs and Ham"}] {:type-name :metadata-type})
      result (transform-keys csk/->kebab-case-keyword m)]
  (check "meta vec maps"
         [{:the-author "Dr. Seuss" :the-title "Green Eggs and Ham"}]
         result)
  (check "meta vec maps preserved" {:type-name :metadata-type} (meta result)))

(let [m (with-meta {'total_books 1 "allBooks" [{'THE_AUTHOR "Dr. Seuss" "the_Title" "Green Eggs and Ham"}]} {:type-name :metadata-type})
      result (transform-keys csk/->kebab-case-keyword m)]
  (check "meta nested"
         {:total-books 1 :all-books [{:the-author "Dr. Seuss" :the-title "Green Eggs and Ham"}]}
         result)
  (check "meta nested preserved" {:type-name :metadata-type} (meta result)))

(println "\n=== Summary ===")
(println (str "Pass: " @pass-count))
(println (str "Fail: " @fail-count))
(let [total (+ @pass-count @fail-count)]
  (println (str "Total: " total))
  (when (pos? total)
    (println (str "Pass rate: " (int (* 100 (/ @pass-count total))) "%"))))
