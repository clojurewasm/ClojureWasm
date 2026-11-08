;; How every scalar prints, and how `pr` differs from `println`.
;; A change in any of these lines is a change in what every user sees.
(doseq [v [nil true false 0 -1 42 3.14 1/3 \a \newline "s" "with \"quote\"" :kw :ns/kw 'sym 'ns/sym]]
  (pr v)
  (print " | ")
  (println v))
