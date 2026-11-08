;; Float rendering: the one-fractional-digit rule, the exponent boundary, and
;; the non-finite forms.
(prn 0.0 -0.0 1.0 -1.0 0.5 -0.5)
(prn 100.0 1000000.0 1.0E7 1.0E-3 1.0E-5)
(prn 1.0E20 1.0E-20 3.141592653589793 2.718281828459045)
(prn (/ 1.0 0.0) (/ -1.0 0.0) (- (/ 1.0 0.0) (/ 1.0 0.0)))
(prn Double/MAX_VALUE Double/MIN_VALUE)
(prn (str 1.0) (str 1.0E20) (pr-str 0.5) (str (/ 1.0 0.0)))
