;; CW compatibility tests for clojure.data.csv
;; Based on upstream: clojure/data.csv src/test/clojure/clojure/data/csv_test.clj
;; Upstream tests: 4 deftests, ~20 assertions
;; CW adaptation: String-based API (no java.io.Reader/Writer)

(require '[clojure.data.csv :as csv])
(require '[clojure.string :as str])

(def test-count (volatile! 0))
(def pass-count (volatile! 0))
(def fail-count (volatile! 0))

(defn assert= [msg expected actual]
  (vswap! test-count inc)
  (if (= expected actual)
    (vswap! pass-count inc)
    (do (vswap! fail-count inc)
        (println (str "FAIL: " msg))
        (println (str "  expected: " (pr-str expected)))
        (println (str "  actual:   " (pr-str actual))))))

(defn assert-true [msg val]
  (vswap! test-count inc)
  (if val
    (vswap! pass-count inc)
    (do (vswap! fail-count inc)
        (println (str "FAIL: " msg)))))

;; === Test Data ===

(def simple
  "Year,Make,Model\n1997,Ford,E350\n2000,Mercury,Cougar\n")

(def simple-alt-sep
  "Year;Make;Model\n1997;Ford;E350\n2000;Mercury;Cougar\n")

(def complicated
  "1997,Ford,E350,\"ac, abs, moon\",3000.00\n1999,Chevy,\"Venture \"\"Extended Edition\"\"\",\"\",4900.00\n1999,Chevy,\"Venture \"\"Extended Edition, Very Large\"\"\",\"\",5000.00\n1996,Jeep,Grand Cherokee,\"MUST SELL!\nair, moon roof, loaded\",4799.00")

;; === Reading Tests (upstream: reading) ===

(println "=== Reading Tests ===")

(let [csv (csv/read-csv simple)]
  (assert= "simple: count" 3 (count csv))
  (assert= "simple: first count" 3 (count (first csv)))
  (assert= "simple: first row" ["Year" "Make" "Model"] (first csv))
  (assert= "simple: last row" ["2000" "Mercury" "Cougar"] (last csv)))

(let [csv (csv/read-csv simple-alt-sep :separator \;)]
  (assert= "alt-sep: count" 3 (count csv))
  (assert= "alt-sep: first count" 3 (count (first csv)))
  (assert= "alt-sep: first row" ["Year" "Make" "Model"] (first csv))
  (assert= "alt-sep: last row" ["2000" "Mercury" "Cougar"] (last csv)))

(let [csv (csv/read-csv complicated)]
  (assert= "complicated: count" 4 (count csv))
  (assert= "complicated: first count" 5 (count (first csv)))
  (assert= "complicated: first row"
           ["1997" "Ford" "E350" "ac, abs, moon" "3000.00"]
           (first csv))
  (assert= "complicated: last row"
           ["1996" "Jeep" "Grand Cherokee" "MUST SELL!\nair, moon roof, loaded" "4799.00"]
           (last csv)))

;; === Reading and Writing Roundtrip (upstream: reading-and-writing) ===
;; CLJW: Upstream uses StringWriter; CW write-csv returns a String

(println "=== Roundtrip Tests ===")

(let [result (csv/write-csv (csv/read-csv simple))]
  (assert= "roundtrip: simple" simple result))

;; === EOF Error on Quoted Field (upstream: throw-if-quoted-on-eof) ===

(println "=== Error Tests ===")

(let [s "ab,\"de,gh\nij,kl,mn"]
  (try
    (doall (csv/read-csv s))
    (assert-true "eof-in-quoted: should throw" false)
    (catch Exception e
      (assert-true "eof-in-quoted: threw exception" true)
      (assert-true "eof-in-quoted: message contains CSV error"
                   (str/includes? (str e) "CSV error")))))

;; === Line Ending Tests (upstream: parse-line-endings) ===

(println "=== Line Ending Tests ===")

;; LF
(let [csv (csv/read-csv "Year,Make,Model\n1997,Ford,E350")]
  (assert= "lf: count" 2 (count csv))
  (assert= "lf: first" ["Year" "Make" "Model"] (first csv))
  (assert= "lf: second" ["1997" "Ford" "E350"] (second csv)))

;; CR+LF
(let [csv (csv/read-csv "Year,Make,Model\r\n1997,Ford,E350")]
  (assert= "crlf: count" 2 (count csv))
  (assert= "crlf: first" ["Year" "Make" "Model"] (first csv))
  (assert= "crlf: second" ["1997" "Ford" "E350"] (second csv)))

;; CR only
(let [csv (csv/read-csv "Year,Make,Model\r1997,Ford,E350")]
  (assert= "cr: count" 2 (count csv))
  (assert= "cr: first" ["Year" "Make" "Model"] (first csv))
  (assert= "cr: second" ["1997" "Ford" "E350"] (second csv)))

;; CR in quoted field
(let [csv (csv/read-csv "Year,Make,\"Model\"\r1997,Ford,E350")]
  (assert= "cr-quoted: count" 2 (count csv))
  (assert= "cr-quoted: first" ["Year" "Make" "Model"] (first csv))
  (assert= "cr-quoted: second" ["1997" "Ford" "E350"] (second csv)))

;; === Additional CW Tests ===

(println "=== Write Tests ===")

;; Basic write
(assert= "write: basic"
         "a,b,c\n1,2,3\n"
         (csv/write-csv [["a" "b" "c"] ["1" "2" "3"]]))

;; Write with quoting
(assert= "write: quoted comma"
         "\"hello, world\",b\n1,2\n"
         (csv/write-csv [["hello, world" "b"] ["1" "2"]]))

;; Write with embedded quotes
(assert= "write: embedded quotes"
         "\"say \"\"hello\"\"\",b\n"
         (csv/write-csv [["say \"hello\"" "b"]]))

;; Write with newline in field
(assert= "write: newline in field"
         "\"line1\nline2\",b\n"
         (csv/write-csv [["line1\nline2" "b"]]))

;; Write with custom separator
(assert= "write: custom sep"
         "a;b;c\n1;2;3\n"
         (csv/write-csv [["a" "b" "c"] ["1" "2" "3"]] :separator \;))

;; Write with CR+LF newline
(assert= "write: crlf"
         "a,b\r\n1,2\r\n"
         (csv/write-csv [["a" "b"] ["1" "2"]] :newline :cr+lf))

;; Empty input
(assert= "read: empty string" () (csv/read-csv ""))
(assert= "write: empty data" "" (csv/write-csv []))

;; Single cell
(assert= "read: single cell" [["hello"]] (doall (csv/read-csv "hello")))

;; === Summary ===

(println (str "\n=== Results: " @pass-count "/" @test-count " passed ==="))
(when (> @fail-count 0)
  (println (str "FAILURES: " @fail-count))
  (System/exit 1))
