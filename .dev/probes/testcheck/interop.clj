(defprotocol ICell (-get [this]) (-set [this v]))
(deftype Cell [^:unsynchronized-mutable v]
  ICell
  (-get [_] v)
  (-set [this nv] (set! v nv) this))
(let [c (->Cell 1)] (println :proto (-get c)) (-set c 7) (println :after (-get c)))
(println :dot-on-deftype
  (try (let [c (->Cell 2)] (.get c)) (catch Throwable e (str "ERR:" (.getMessage e)))))
(println :reify-dot
  (try (let [r (reify Object (toString [_] "hi"))] (str r)) (catch Throwable e (str "ERR:" (.getMessage e)))))
