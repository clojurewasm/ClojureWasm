;; N-Queens solver — simple recursive backtracking
(defn abs [x] (if (< x 0) (- 0 x) x))

(defn safe? [queens col row]
  (loop [qs queens r (- row 1)]
    (if (nil? (seq qs))
      true
      (let [qc (first qs)]
        (if (or (= qc col)
                (= (abs (- qc col)) (- row r)))
          false
          (recur (rest qs) (- r 1)))))))

(defn solve [n row queens]
  (if (= row n)
    1
    (loop [col 0 count 0]
      (if (= col n)
        count
        (recur (+ col 1)
               (if (safe? queens col row)
                 (+ count (solve n (+ row 1) (cons col queens)))
                 count))))))

(println (solve 8 0 (list)))
