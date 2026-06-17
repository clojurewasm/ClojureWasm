;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.pprint API (originally Tom Faulhaber; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.pprint — minimum pretty-print surface. cw v1 §9.12 row 10.2.
;;
;; Pattern A defns over clojure.core/println + clojure.string/join.
;; `pprint` currently aliases to `println` (cw v1's default `prn`
;; output already matches JVM short-form pretty-print for the
;; map / vector / set / list literals that the existing reader
;; produces); a real width-aware indenter is deferred until
;; user demand surfaces.
;; `print-table` formats a seq of maps with shared keys as a
;; pipe-separated table; takes the keys from the first row.
;; `cl-format` and the rest of JVM clojure.pprint surface are
;; deferred — they require a non-trivial formatting DSL impl that
;; lands when needed.
(ns clojure.pprint
  (:refer-clojure))

;; Dispatch surface (D-402). cljw has no width-aware indenter / code-specific
;; formatter, so both dispatches are the SAME pr-readable single-line printer (a
;; documented divergence from JVM pprint's multi-line layout + code indentation).
;; The indirection exists so `with-pprint-dispatch` / `code-dispatch` resolve and
;; bind — what macro-pretty-printing libs need (clojure.tools.logging's `spy`).
;; Using `pr` (not `println`) also fixes the string-quoting divergence: cljw
;; `(pprint "x")` now prints `"x"`, matching clj, not the bare `x` println gave.
(def simple-dispatch (fn* [x] (pr x)))
(def code-dispatch (fn* [x] (pr x)))

(def ^:dynamic *print-pprint-dispatch* simple-dispatch)

(defmacro with-pprint-dispatch
  "Evaluate `body` with *print-pprint-dispatch* bound to `dispatch`."
  [dispatch & body]
  `(binding [*print-pprint-dispatch* ~dispatch] ~@body))

(def pprint
  (fn* [x] (*print-pprint-dispatch* x) (newline)))

;; `print-table` — clj's exact format (F-011): a leading blank line, a padded
;; `| col | col |` header, a `|----+----|` rule, then one padded row per map.
;; Column width = max(key width, widest value). `ks` defaults to the first row's
;; keys. Ported from clojure.pprint/print-table (was a simpler non-matching form).
(defn print-table
  ([ks rows]
   (when (seq rows)
     (let [widths (map (fn [k] (apply max (count (str k)) (map (fn [r] (count (str (get r k)))) rows))) ks)
           spacers (map (fn [w] (apply str (repeat w "-"))) widths)
           fmts (map (fn [w] (str "%" w "s")) widths)
           fmt-row (fn [leader divider trailer row]
                     (str leader
                          (apply str (interpose divider
                                                (for [pair (map vector (map (fn [k] (get row k)) ks) fmts)]
                                                  (format (second pair) (str (first pair))))))
                          trailer))]
       (println)
       (println (fmt-row "| " " | " " |" (zipmap ks ks)))
       (println (fmt-row "|-" "-+-" "-|" (zipmap ks spacers)))
       (doseq [row rows] (println (fmt-row "| " " | " " |" row))))))
  ([rows] (print-table (keys (first rows)) rows)))

;; `(cl-format stream fmt & args)` — Common-Lisp-format subset (D-403 + D-455).
;; ~A aesthetic, ~S standard (pr-readable), ~D decimal, ~F fixed float, ~X/~O radix,
;; ~B binary, ~R numerals (~R cardinal / ~:R ordinal / ~@R Roman / ~NR radix),
;; ~{~^~} list iteration, ~(~) case-region (~( lower / ~:( cap-words / ~@( cap-first
;; / ~:@( upper), ~% newline, ~C char, ~& fresh-line (~N& adds N-1 more), ~P plural
;; (~:P back-up / ~@P y-ies), ~* arg-jump (~N* / ~N:* / ~N@*), ~T tabulate, ~$ monetary,
;; ~E/~G exponential/general float (CLtL Steele; full ~w,d,e,k,oc,pc,exp param surface),
;; ~~ literal ~. The `~param,'padchar` grammar also parses negative params (~9,3,2,-2E)
;; and char params. A nil stream returns the string; any other stream prints to *out*
;; + returns nil. Still raising (no silent mishandle): ~[~]/~<~> (conditional/justify,
;; D-455 chunk4) and the `V`/`#` runtime-valued params (a cl-dir gap, D-458).
(defn cl-digit? [c] (let [i (int c)] (and (>= i (int \0)) (<= i (int \9)))))
(defn cl-int [c] (- (int c) (int \0)))

;; Parse a directive's `~[params][:][@]d` prefix from `fmt` starting at `i` (the
;; char just after `~`). Returns [params colon? at? directive-char next-i], where
;; params is a vector of (long | char | nil) — `~5,'0d` → [5 \0], `~,2f` → [nil 2].
(defn cl-dir [fmt i]
  (loop [j i params [] cur nil cur? false neg? false colon? false at? false]
    (let [c (nth fmt j)
          signed (fn [v] (if neg? (- v) v))]
      (cond
        (and (= c \-) (not cur?) (not neg?)) (recur (inc j) params cur cur? true colon? at?)
        (cl-digit? c) (recur (inc j) params (+ (* (or cur 0) 10) (cl-int c)) true neg? colon? at?)
        (= c \') (recur (+ j 2) params (nth fmt (inc j)) true false colon? at?)
        (= c \,) (recur (inc j) (conj params (if cur? (signed cur) nil)) nil false false colon? at?)
        (= c \:) (recur (inc j) params cur cur? neg? true at?)
        (= c \@) (recur (inc j) params cur cur? neg? colon? true)
        :else [(if cur? (conj params (signed cur)) params) colon? at? c (inc j)]))))

;; Left-pad `s` to `width` with `padchar` (CL-format right-justification default).
(defn cl-pad [s width padchar]
  (let [len (count s) w (or width 0)]
    (if (< len w) (str (apply str (repeat (- w len) padchar)) s) s)))

;; Find the sub-format between an opener (at index `i`) and its matching `~<close>`
;; (`~}` for iteration, `~)` for case). Returns [subfmt next-i]. (Non-nested.)
(defn cl-close [fmt i close]
  (loop [j i]
    (if (and (= (nth fmt j) \~) (= (nth fmt (inc j)) close)) [(subs fmt i j) (+ j 2)] (recur (inc j)))))

;; Capitalize the first letter of each space-separated word, lowercasing the rest
;; (the `~:(` transform). Manual char walk — a regex literal cannot live in a
;; bundled `.clj` (cycle-1 reader limitation).
(defn cl-cap-words [s]
  (loop [cs (seq s) prev-space? true acc ""]
    (if (nil? cs)
      acc
      (let [c (first cs) sp? (= c \space)]
        (recur (next cs) sp?
               (str acc (if (and prev-space? (not sp?))
                          (clojure.string/upper-case (str c))
                          (clojure.string/lower-case (str c)))))))))

;; `~(`-region case transform per the `:`/`@` flags: ~( lower / ~:( cap-each-word
;; / ~@( cap-first / ~:@( upper.
(defn cl-case [s colon? at?]
  (cond
    (and colon? at?) (clojure.string/upper-case s)
    colon? (cl-cap-words s)
    at? (clojure.string/capitalize s)
    :else (clojure.string/lower-case s)))

;; ~R numeral directives. cl-cardinal n → English words ("forty-two");
;; groups of 3 digits are joined with ", " (clj-faithful). cl-ordinal → "forty-
;; second" (the last cardinal word gets the ordinal suffix). cl-roman → subtractive
;; Roman ("XLII"). Radix (~NR) is `(Long/toString n base)` inline in cl-run.
(def cl-ones ["zero" "one" "two" "three" "four" "five" "six" "seven" "eight" "nine"
              "ten" "eleven" "twelve" "thirteen" "fourteen" "fifteen" "sixteen"
              "seventeen" "eighteen" "nineteen"])
(def cl-tens ["" "" "twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"])
(def cl-scales ["" " thousand" " million" " billion" " trillion" " quadrillion"])
(defn cl-under-100 [n]
  (cond (< n 20) (cl-ones n)
        (zero? (rem n 10)) (cl-tens (quot n 10))
        :else (str (cl-tens (quot n 10)) "-" (cl-ones (rem n 10)))))
(defn cl-under-1000 [n]
  (if (< n 100)
    (cl-under-100 n)
    (let [h (quot n 100) r (rem n 100)]
      (str (cl-ones h) " hundred" (when (pos? r) (str " " (cl-under-100 r)))))))
(defn cl-cardinal [n]
  (cond (zero? n) "zero"
        (neg? n) (str "minus " (cl-cardinal (- n)))
        :else (loop [n n i 0 parts ()]
                (if (zero? n)
                  (clojure.string/join ", " parts)
                  (let [grp (rem n 1000)]
                    (recur (quot n 1000) (inc i)
                           (if (pos? grp) (cons (str (cl-under-1000 grp) (cl-scales i)) parts) parts)))))))
(def cl-ord-ones {"one" "first" "two" "second" "three" "third" "five" "fifth"
                  "eight" "eighth" "nine" "ninth" "twelve" "twelfth"})
(defn cl-ordinalize-word [w]
  (cond (contains? cl-ord-ones w) (cl-ord-ones w)
        (clojure.string/ends-with? w "y") (str (subs w 0 (dec (count w))) "ieth")
        :else (str w "th")))
(defn cl-ordinal [n]
  (let [c (cl-cardinal n) idx (max (.lastIndexOf c " ") (.lastIndexOf c "-"))]
    (str (subs c 0 (inc idx)) (cl-ordinalize-word (subs c (inc idx))))))
(def cl-roman-pairs [[1000 "M"] [900 "CM"] [500 "D"] [400 "CD"] [100 "C"] [90 "XC"]
                     [50 "L"] [40 "XL"] [10 "X"] [9 "IX"] [5 "V"] [4 "IV"] [1 "I"]])
(defn cl-roman [n]
  (loop [n n acc "" pairs cl-roman-pairs]
    (if (or (zero? n) (empty? pairs))
      acc
      (let [pr (first pairs) v (first pr) s (second pr)]
        (if (>= n v) (recur (- n v) (str acc s) pairs) (recur n acc (rest pairs)))))))

(declare cl-iter)

;; Current output column = chars since the last newline in `s` (~T uses it).
(defn cl-col [s]
  (loop [i (dec (count s)) c 0]
    (if (or (< i 0) (= (nth s i) \newline)) c (recur (dec i) (inc c)))))

;; ~T tabulate: spaces to reach column `colnum`; if already at/past it, advance
;; to the next `colinc` multiple beyond `colnum` (CL semantics; colinc<=0 = no-op).
(defn cl-tab [acc colnum colinc]
  (let [col (cl-col acc)
        need (if (< col colnum)
               (- colnum col)
               (if (<= colinc 0) 0 (- colinc (mod (- col colnum) colinc))))]
    (apply str (repeat (max 0 need) \space))))

;; ~$ monetary: ~d,n,w,padchar$ — d decimals after point (default 2), n minimum
;; integer digits (default 1, zero-padded), w minimum total width, padchar (default
;; space). `@` forces a leading "+" on non-negatives. `:` places the sign before the
;; width padding (`@:` → "+    12.0"); the default folds the sign into the padded body.
(defn cl-money [x dec n w padc at? colon?]
  (let [neg? (neg? x)
        mag (format (str "%." dec "f") (if neg? (- (double x)) (double x)))
        di (clojure.string/index-of mag ".")
        intp (if di (subs mag 0 di) mag)
        frac (if di (subs mag di) "")
        intp (if (< (count intp) n) (str (apply str (repeat (- n (count intp)) \0)) intp) intp)
        sign (cond neg? "-" at? "+" :else "")
        body (str intp frac)]
    (if (and colon? (not= sign ""))
      (str sign (cl-pad body (when w (- w (count sign))) padc))
      (cl-pad (str sign body) w padc))))

;; ── Float printing for ~E / ~G (CLtL Steele algorithm) ──────────────────────
;; Re-derived (variant ②) as string-returning fns. The key trick: derive the
;; shortest decimal digit string + exponent from the host's `(str f)` (which is
;; already shortest-round-trip), then reformat — no Ratio/BigDecimal machinery.

(defn cl-rtrim [s c]
  (loop [n (count s)] (if (and (pos? n) (= (nth s (dec n)) c)) (recur (dec n)) (subs s 0 n))))
(defn cl-ltrim [s c]
  (loop [n 0] (if (and (< n (count s)) (= (nth s n) c)) (recur (inc n)) (subs s n))))

;; Decompose (str f) into [digit-string exp]: value's first digit sits at 10^exp.
(defn cl-float-parts-base [f]
  (let [s (clojure.string/lower-case (str f))
        eloc (clojure.string/index-of s "e")
        dloc (clojure.string/index-of s ".")]
    (if (nil? eloc)
      (if (nil? dloc)
        [s (str (dec (count s)))]
        [(str (subs s 0 dloc) (subs s (inc dloc))) (str (dec dloc))])
      (if (nil? dloc)
        [(subs s 0 eloc) (subs s (inc eloc))]
        [(str (subs s 0 1) (subs s 2 eloc)) (subs s (inc eloc))]))))

(defn cl-float-parts [f]
  (let [pb (cl-float-parts-base f) m (nth pb 0) e (nth pb 1)
        m1 (cl-rtrim m \0) m2 (cl-ltrim m1 \0)
        delta (- (count m1) (count m2))
        e (if (and (pos? (count e)) (= (nth e 0) \+)) (subs e 1) e)]
    (if (= (count m2) 0) ["0" 0] [m2 (- (parse-long e) delta)])))

;; Increment a decimal digit-string by 1 (carries; may grow by a digit).
(defn cl-inc-s [s]
  (let [len-1 (dec (count s))]
    (loop [i len-1]
      (cond
        (neg? i) (apply str "1" (repeat (inc len-1) "0"))
        (= \9 (nth s i)) (recur (dec i))
        :else (apply str (subs s 0 i) (char (inc (int (nth s i)))) (repeat (- len-1 i) "0"))))))

;; Round digit-string `m` (first digit at 10^e) to `d` fraction digits / `w` width.
;; Returns [rounded-digits exp expanded?] (expanded? = carry grew the exponent).
(defn cl-round-str [m e d w]
  (if (or d w)
    (let [len (count m)
          w (if w (max 2 w) nil)
          round-pos (cond d (+ e d 1) (>= e 0) (max (inc e) (dec w)) :else (+ w e))
          rp0 (= round-pos 0)
          m1 (if rp0 (str "0" m) m)
          e1 (if rp0 (inc e) e)
          round-pos (if rp0 1 round-pos)
          len (if rp0 (inc len) len)]
      (if (neg? round-pos)
        ["0" 0 false]
        (if (> len round-pos)
          (let [round-char (nth m1 round-pos) result (subs m1 0 round-pos)]
            (if (>= (int round-char) (int \5))
              (let [rur (cl-inc-s result) expanded (> (count rur) (count result))]
                [(if expanded (subs rur 0 (dec (count rur))) rur) e1 expanded])
              [result e1 false]))
          [m e false])))
    [m e false]))

(defn cl-expand-fixed [m e d]
  (let [m1 (if (neg? e) (str (apply str (repeat (dec (- e)) \0)) m) m)
        e1 (if (neg? e) -1 e)
        len (count m1)
        target-len (if d (+ e1 d 1) (inc e1))]
    (if (< len target-len) (str m1 (apply str (repeat (- target-len len) \0))) m1)))

(defn cl-insert-decimal [m e]
  (if (neg? e) (str "." m) (str (subs m 0 (inc e)) "." (subs m (inc e)))))
(defn cl-get-fixed [m e d] (cl-insert-decimal (cl-expand-fixed m e d) e))
(defn cl-insert-scaled-decimal [m k]
  (if (neg? k) (str "." m) (str (subs m 0 k) "." (subs m k))))

;; Fixed-format float (the ~F engine, also ~G's fixed branch). String form of v0's
;; fixed-float. w width, d fraction digits, k scale, oc overflow char, pc pad char.
(defn cl-ffixed [x w d k oc pc at?]
  (let [neg? (neg? x)
        sign (if neg? "-" "+")
        fp (cl-float-parts (if neg? (- (double x)) (double x)))
        mantissa (nth fp 0) exp (nth fp 1)
        scaled-exp (+ exp k)
        add-sign (or at? neg?)
        append-zero (and (not d) (<= (dec (count mantissa)) scaled-exp))
        rs (cl-round-str mantissa scaled-exp d (if w (- w (if add-sign 1 0)) nil))
        rm (nth rs 0) se2 (nth rs 1) expanded (nth rs 2)
        fr (cl-get-fixed rm (if expanded (inc se2) se2) d)
        fr (if (and w d (>= d 1) (= (nth fr 0) \0) (= (nth fr 1) \.)
                    (> (count fr) (- w (if add-sign 1 0))))
             (subs fr 1) fr)
        prepend-zero (= (first fr) \.)]
    (if w
      (let [len (count fr)
            signed-len (if add-sign (inc len) len)
            prepend-zero (and prepend-zero (not (>= signed-len w)))
            append-zero (and append-zero (not (>= signed-len w)))
            full-len (if (or prepend-zero append-zero) (inc signed-len) signed-len)]
        (if (and (> full-len w) oc)
          (apply str (repeat w oc))
          (str (apply str (repeat (- w full-len) pc))
               (if add-sign sign "") (if prepend-zero "0" "") fr (if append-zero "0" ""))))
      (str (if add-sign sign "") (if prepend-zero "0" "") fr (if append-zero "0" "")))))

;; Exponential-format float (~E). Params w,d,e(exp digits),k(scale),expchar,oc,pc.
(defn cl-efloat [x w d e k expchar oc pc at?]
  (let [negx? (neg? x)
        fp (cl-float-parts (if negx? (- (double x)) (double x)))]
    (loop [mantissa (nth fp 0) exp (nth fp 1)]
      (let [add-sign (or at? negx?)
            prepend-zero (<= k 0)
            scaled-exp (- exp (dec k))
            sea (if (neg? scaled-exp) (- scaled-exp) scaled-exp)
            ses (str sea)
            ses (str expchar (if (neg? scaled-exp) \- \+)
                     (if e (apply str (repeat (- e (count ses)) \0)) "") ses)
            exp-width (count ses)
            base-mw (count mantissa)
            sm (str (apply str (repeat (- k) \0)) mantissa
                    (if d (apply str (repeat (- d (dec base-mw) (if (neg? k) (- k) 0)) \0)) ""))
            wm (if w (- w exp-width) nil)
            rs (cl-round-str sm 0 (cond (= k 0) (dec d) (pos? k) d :else (dec d))
                             (if wm (- wm (if add-sign 1 0)) nil))
            rm (nth rs 0) incr-exp (nth rs 2)
            fm (cl-insert-scaled-decimal rm k)
            append-zero (and (= k (count rm)) (nil? d))]
        (if (not incr-exp)
          (if w
            (let [len (+ (count fm) exp-width)
                  signed-len (if add-sign (inc len) len)
                  prepend-zero (and prepend-zero (not (= signed-len w)))
                  full-len (if prepend-zero (inc signed-len) signed-len)
                  append-zero (and append-zero (< full-len w))]
              (if (and (or (> full-len w) (and e (> (- exp-width 2) e))) oc)
                (apply str (repeat w oc))
                (str (apply str (repeat (- w full-len (if append-zero 1 0)) pc))
                     (if add-sign (if negx? "-" "+") "") (if prepend-zero "0" "")
                     fm (if append-zero "0" "") ses)))
            (str (if add-sign (if negx? "-" "+") "") (if prepend-zero "0" "")
                 fm (if append-zero "0" "") ses))
          (recur rm (inc exp)))))))

;; General float (~G): pick fixed or exponential by magnitude, per CLtL.
(defn cl-gfloat [x w d e k expchar oc pc at?]
  (let [neg? (neg? x)
        fp (cl-float-parts (if neg? (- (double x)) (double x)))
        mantissa (nth fp 0) exp (nth fp 1)
        n (if (== (double x) 0.0) 0 (inc exp))
        ee (if e (+ e 2) 4)
        ww (if w (- w ee) nil)
        dd (if d d (max (count mantissa) (min n 7)))
        ddd (- dd n)]
    (if (and (<= 0 ddd) (<= ddd dd))
      (str (cl-ffixed x ww ddd 0 oc pc at?) (apply str (repeat ee \space)))
      (cl-efloat x w d e k expchar oc pc at?))))

;; Run `fmt` over the operand vector `argv` from index `pos0`, returning
;; [acc next-pos]. The index navigator lets ~* jump and ~:P / ~:* back up. `~^`
;; (escape) returns early, which `~{~}` iteration uses to stop before the
;; trailing separator once the operands are exhausted.
(defn cl-run [fmt argv pos0]
  (let [n (count fmt) na (count argv)]
    (loop [i 0 pos pos0 acc ""]
      (if (>= i n)
        [acc pos]
        (let [c (nth fmt i)]
          (if (and (= c \~) (< (inc i) n))
            (let [pd (cl-dir fmt (inc i))
                  params (nth pd 0) colon? (nth pd 1) at? (nth pd 2) d (nth pd 3) ni (nth pd 4)
                  p0 (first params) p1 (second params)
                  x (when (< pos na) (nth argv pos))]
              (cond
                (or (= d \a) (= d \A)) (recur ni (inc pos) (str acc (if (string? x) x (pr-str x))))
                (or (= d \s) (= d \S)) (recur ni (inc pos) (str acc (pr-str x)))
                (or (= d \d) (= d \D))
                (recur ni (inc pos) (str acc (cl-pad (if colon? (format "%,d" x) (str x)) p0 (or p1 \space))))
                (or (= d \f) (= d \F))
                (recur ni (inc pos) (str acc (format (str "%" (if p0 p0 "") "." (or p1 0) "f") (double x))))
                (or (= d \x) (= d \X)) (recur ni (inc pos) (str acc (cl-pad (format "%x" x) p0 (or p1 \space))))
                (or (= d \o) (= d \O)) (recur ni (inc pos) (str acc (cl-pad (format "%o" x) p0 (or p1 \space))))
                (or (= d \b) (= d \B)) (recur ni (inc pos) (str acc (cl-pad (Long/toBinaryString x) p0 (or p1 \space))))
                (or (= d \r) (= d \R))
                (recur ni (inc pos) (str acc (cond p0 (Long/toString x p0)
                                                   at? (cl-roman x)
                                                   colon? (cl-ordinal x)
                                                   :else (cl-cardinal x))))
                ;; ~{...~} — iterate over a list arg (~@{ over the remaining args).
                (= d \{)
                (let [cl (cl-close fmt ni \})]
                  (if at?
                    (recur (nth cl 1) na (str acc (cl-iter (nth cl 0) (subvec argv (min pos na)))))
                    (recur (nth cl 1) (inc pos) (str acc (cl-iter (nth cl 0) x)))))
                (= d \()
                (let [cl (cl-close fmt ni \)) r (cl-run (nth cl 0) argv pos)]
                  (recur (nth cl 1) (nth r 1) (str acc (cl-case (nth r 0) colon? at?))))
                (= d \^) (if (>= pos na) [acc pos] (recur ni pos acc))
                (= d \%) (recur ni pos (str acc \newline))
                ;; ~T — tabulate: pad with spaces to reach column p0 (default 1),
                ;; then at least colinc=p1 (default 1) more if already at/past it.
                (or (= d \t) (= d \T)) (recur ni pos (str acc (cl-tab acc (or p0 1) (or p1 1))))
                ;; ~P plural — "s" unless arg is 1; ~@P → y/ies; ~:P backs up to
                ;; re-read the previous arg (the common "~D dog~:P" idiom).
                (or (= d \p) (= d \P))
                (let [pv (if colon? (nth argv (dec pos)) x)
                      np (if colon? pos (inc pos))]
                  (recur ni np (str acc (if at? (if (= pv 1) "y" "ies") (if (= pv 1) "" "s")))))
                ;; ~* arg-jump — ~N* forward N (default 1), ~N:* back N, ~N@* absolute.
                (= d \*)
                (let [np (cond at? (or p0 0)
                               colon? (- pos (or p0 1))
                               :else (+ pos (or p0 1)))]
                  (recur ni np acc))
                ;; ~C — print a character (plain; ~:C/~@C named/readable variants
                ;; are not modelled).
                (and (or (= d \c) (= d \C)) (not colon?) (not at?)) (recur ni (inc pos) (str acc x))
                ;; ~& — fresh-line: a newline only if not already at line start;
                ;; ~N& adds N-1 further newlines.
                (= d \&)
                (let [fresh (if (or (= acc "") (= (last acc) \newline)) acc (str acc \newline))]
                  (recur ni pos (apply str fresh (repeat (if p0 (dec p0) 0) \newline))))
                ;; ~E — exponential float (params ~w,d,e,k,overflowchar,padchar,exponentchar).
                (or (= d \e) (= d \E))
                (recur ni (inc pos)
                       (str acc (cl-efloat x p0 p1 (nth params 2 nil) (or (nth params 3 nil) 1)
                                           (or (nth params 6 nil) \E) (nth params 4 nil)
                                           (or (nth params 5 nil) \space) at?)))
                ;; ~G — general float (chooses fixed vs exponential by magnitude).
                (or (= d \g) (= d \G))
                (recur ni (inc pos)
                       (str acc (cl-gfloat x p0 p1 (nth params 2 nil) (or (nth params 3 nil) 1)
                                           (or (nth params 6 nil) \E) (nth params 4 nil)
                                           (or (nth params 5 nil) \space) at?)))
                ;; ~$ — monetary fixed-format (params ~d,n,w,padchar$).
                (= d \$)
                (recur ni (inc pos)
                       (str acc (cl-money x (or p0 2) (or p1 1) (nth params 2 nil) (or (nth params 3 nil) \space) at? colon?)))
                (= d \~) (recur ni pos (str acc \~))
                :else (throw (ex-info (str "cl-format: directive ~" d " is not supported in ClojureWasm") {}))))
            (recur (inc i) pos (str acc c))))))))

;; Apply `subfmt` repeatedly over `lst`, consuming elements each pass; `~^` in
;; `subfmt` exits when the list is exhausted (so the trailing separator is dropped
;; on the last element). `(cl-run subfmt items)` returning `items` unchanged means
;; `~^` fired with nothing consumed → stop.
(defn cl-iter [subfmt lst]
  (let [v (vec lst) nv (count v)]
    (loop [pos 0 acc ""]
      (if (>= pos nv)
        acc
        (let [r (cl-run subfmt v pos)]
          (if (= (nth r 1) pos) acc (recur (nth r 1) (str acc (nth r 0)))))))))

(defn cl-format [stream fmt & args]
  (let [result (nth (cl-run fmt (vec args) 0) 0)]
    (if (nil? stream) result (do (print result) nil))))
