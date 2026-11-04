;; Byte Array From Seq: (byte-array (repeat 8000 1)), 20 times. Times filling
;; a primitive array from a lazy seq source. Prints the total length.
(loop [i 0 n 0]
  (if (< i 20)
    (recur (inc i) (+ n (alength (byte-array (repeat 8000 1)))))
    (println n)))
