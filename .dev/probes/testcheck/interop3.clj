(defprotocol IThing (get [this]) (put [this v]))
(deftype T [^:unsynchronized-mutable v] IThing (get [_] v) (put [this x] (set! v x) this))
(let [t (->T 1)]
  (println :proto-call (get t))
  (println :dot-call (try (.get t) (catch Throwable e (str "ERR:" (.getMessage e))))))
