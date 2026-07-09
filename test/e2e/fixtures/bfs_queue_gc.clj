;; Regression fixture for the D-556-class vm-backend BFS queue corruption
;; (user report 2026-07-07): a 2-list FIFO queue ([state path] pairs pushed
;; via `into` from a `for`+:let+:when lazy seq, requeued with `reverse`,
;; alongside a growing `visited` set) had queue elements decay into raw
;; numbers mid-loop — `(first front)` returned a Long instead of the
;; [state path] vector. Root cause: the vm's not-yet-executed fn literal
;; pool was unrooted (same hole the persist-analysis-roots fix closed).
;; Board-logic-free minimal repro; clj prints the identical WON line.
(ns bfs-queue-gc)

(defn solve2
  [start max-depth max-states]
  (loop [front (list [start []])
         back ()
         visited #{start}]
    (cond
      (and (empty? front) (empty? back)) (println "EXHAUSTED visited=" (count visited))
      (>= (count visited) max-states) (println "CAPPED visited=" (count visited))
      (empty? front) (recur (reverse back) () visited)
      :else
      (let [head (first front)]
        (if-not (vector? head)
          (println "CORRUPT head=" head "type=" (type head))
          (let [[state path] head
                front (rest front)]
            (cond
              (>= state 30) (println "WON path=" path)
              (>= (count path) max-depth) (recur front back visited)
              :else
              (let [next-states (for [d [1 2 3]
                                      :let [state' (+ state d)]
                                      :when (not (visited state'))]
                                  [state' (conj path d)])]
                (recur front
                       (into back next-states)
                       (into visited (map first next-states)))))))))))

(solve2 0 24 1000)
