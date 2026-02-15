;; UPSTREAM-DIFF: CW pprint — atom-based XP algorithm, no ref/proxy/Writer
(ns clojure.pprint)

(defn- rtrim-whitespace [s]
  (let [len (count s)]
    (if (zero? len)
      s
      (loop [n (dec len)]
        (cond
          (neg? n) ""
          (not (Character/isWhitespace (.charAt ^String s n))) (subs s 0 (inc n))
          true (recur (dec n)))))))

(def ^:dynamic ^{:private true} *default-page-width* 72)

(defn- column-writer
  ([writer] (column-writer writer *default-page-width*))
  ([writer max-columns]
   (atom {:max max-columns :cur 0 :line 0 :base writer})))

(defn- get-column [cw] (:cur @cw))
(defn- get-max-column [cw] (:max @cw))

(defn- cw-write-char [cw c]
  (if (= c \newline)
    (swap! cw #(-> % (assoc :cur 0) (update :line inc)))
    (swap! cw update :cur inc))
  (print (str c)))

(defn- last-index-of-char [s c]
  (loop [i (dec (count s))]
    (cond
      (neg? i) -1
      (= (.charAt ^String s i) c) i
      :else (recur (dec i)))))

(defn- cw-write-string [cw s]
  (let [nl (last-index-of-char s \newline)]
    (if (neg? nl)
      (swap! cw update :cur + (count s))
      (swap! cw #(-> %
                     (assoc :cur (- (count s) nl 1))
                     (update :line + (count (filter (fn [ch] (= ch \newline)) s)))))))
  (print s))

(declare get-miser-width)

(defmacro ^{:private true} getf [pw sym]
  `(~sym @~pw))

(defmacro ^{:private true} setf [pw sym new-val]
  `(swap! ~pw assoc ~sym ~new-val))

(defn- make-buffer-blob [data trailing-ws start-pos end-pos]
  {:type-tag :buffer-blob :data data :trailing-white-space trailing-ws
   :start-pos start-pos :end-pos end-pos})

(defn- make-nl-t [type logical-block start-pos end-pos]
  {:type-tag :nl-t :type type :logical-block logical-block
   :start-pos start-pos :end-pos end-pos})

(defn- nl-t? [x] (= (:type-tag x) :nl-t))

(defn- make-start-block-t [logical-block start-pos end-pos]
  {:type-tag :start-block-t :logical-block logical-block
   :start-pos start-pos :end-pos end-pos})

(defn- make-end-block-t [logical-block start-pos end-pos]
  {:type-tag :end-block-t :logical-block logical-block
   :start-pos start-pos :end-pos end-pos})

(defn- make-indent-t [logical-block relative-to offset start-pos end-pos]
  {:type-tag :indent-t :logical-block logical-block :relative-to relative-to
   :offset offset :start-pos start-pos :end-pos end-pos})

(defn- make-logical-block [parent section start-col indent done-nl intra-block-nl
                           prefix per-line-prefix suffix]
  {:parent parent :section section
   :start-col (atom start-col) :indent (atom indent)
   :done-nl (atom done-nl) :intra-block-nl (atom intra-block-nl)
   :prefix prefix :per-line-prefix per-line-prefix :suffix suffix})

(defn- ancestor? [parent child]
  (loop [child (:parent child)]
    (cond
      (nil? child) false
      (identical? parent child) true
      :else (recur (:parent child)))))

(defn- buffer-length [l]
  (let [l (seq l)]
    (if l
      (- (:end-pos (last l)) (:start-pos (first l)))
      0)))

(def ^:dynamic ^{:private true} *pw* nil)

(defn- pw-base-write [pw s]
  (let [base (getf pw :base)]
    (cw-write-string base s)))

(defn- pw-base-write-char [pw c]
  (let [base (getf pw :base)]
    (cw-write-char base c)))

(defn- pp-newline [] "\n")

(declare emit-nl)

(defmulti ^{:private true} write-token (fn [pw token] (:type-tag token)))

(defmethod write-token :start-block-t [pw token]
  (when-let [cb (getf pw :logical-block-callback)] (cb :start))
  (let [lb (:logical-block token)]
    (when-let [prefix (:prefix lb)]
      (pw-base-write pw prefix))
    (let [col (get-column (getf pw :base))]
      (reset! (:start-col lb) col)
      (reset! (:indent lb) col))))

(defmethod write-token :end-block-t [pw token]
  (when-let [cb (getf pw :logical-block-callback)] (cb :end))
  (when-let [suffix (:suffix (:logical-block token))]
    (pw-base-write pw suffix)))

(defmethod write-token :indent-t [pw token]
  (let [lb (:logical-block token)]
    (reset! (:indent lb)
            (+ (:offset token)
               (condp = (:relative-to token)
                 :block @(:start-col lb)
                 :current (get-column (getf pw :base)))))))

(defmethod write-token :buffer-blob [pw token]
  (pw-base-write pw (:data token)))

(defmethod write-token :nl-t [pw token]
  (if (or (= (:type token) :mandatory)
          (and (not (= (:type token) :fill))
               @(:done-nl (:logical-block token))))
    (emit-nl pw token)
    (when-let [tws (getf pw :trailing-white-space)]
      (pw-base-write pw tws)))
  (setf pw :trailing-white-space nil))

(defn- write-tokens [pw tokens force-trailing-whitespace]
  (doseq [token tokens]
    (when-not (= (:type-tag token) :nl-t)
      (when-let [tws (getf pw :trailing-white-space)]
        (pw-base-write pw tws)))
    (write-token pw token)
    (setf pw :trailing-white-space (:trailing-white-space token)))
  (let [tws (getf pw :trailing-white-space)]
    (when (and force-trailing-whitespace tws)
      (pw-base-write pw tws)
      (setf pw :trailing-white-space nil))))

(defn- tokens-fit? [pw tokens]
  (let [maxcol (get-max-column (getf pw :base))]
    (or (nil? maxcol)
        (< (+ (get-column (getf pw :base)) (buffer-length tokens)) maxcol))))

(defn- linear-nl? [pw lb section]
  (or @(:done-nl lb)
      (not (tokens-fit? pw section))))

(defn- miser-nl? [pw lb section]
  (let [miser-width (get-miser-width pw)
        maxcol (get-max-column (getf pw :base))]
    (and miser-width maxcol
         (>= @(:start-col lb) (- maxcol miser-width))
         (linear-nl? pw lb section))))

(defmulti ^{:private true} emit-nl? (fn [t _ _ _] (:type t)))

(defmethod emit-nl? :linear [newl pw section _]
  (linear-nl? pw (:logical-block newl) section))

(defmethod emit-nl? :miser [newl pw section _]
  (miser-nl? pw (:logical-block newl) section))

(defmethod emit-nl? :fill [newl pw section subsection]
  (let [lb (:logical-block newl)]
    (or @(:intra-block-nl lb)
        (not (tokens-fit? pw subsection))
        (miser-nl? pw lb section))))

(defmethod emit-nl? :mandatory [_ _ _ _]
  true)

(defn- get-section [buffer]
  (let [nl (first buffer)
        lb (:logical-block nl)
        section (seq (take-while #(not (and (nl-t? %) (ancestor? (:logical-block %) lb)))
                                 (next buffer)))]
    [section (seq (drop (inc (count section)) buffer))]))

(defn- get-sub-section [buffer]
  (let [nl (first buffer)
        lb (:logical-block nl)
        section (seq (take-while #(let [nl-lb (:logical-block %)]
                                    (not (and (nl-t? %)
                                              (or (= nl-lb lb)
                                                  (ancestor? nl-lb lb)))))
                                 (next buffer)))]
    section))

(defn- update-nl-state [lb]
  (reset! (:intra-block-nl lb) false)
  (reset! (:done-nl lb) true)
  (loop [lb (:parent lb)]
    (when lb
      (reset! (:done-nl lb) true)
      (reset! (:intra-block-nl lb) true)
      (recur (:parent lb)))))

(defn- emit-nl [pw nl]
  (pw-base-write pw (pp-newline))
  (setf pw :trailing-white-space nil)
  (let [lb (:logical-block nl)
        prefix (:per-line-prefix lb)]
    (when prefix
      (pw-base-write pw prefix))
    (let [istr (apply str (repeat (- @(:indent lb) (count (or prefix ""))) \space))]
      (pw-base-write pw istr))
    (update-nl-state lb)))

(defn- split-at-newline [tokens]
  (let [pre (seq (take-while #(not (nl-t? %)) tokens))]
    [pre (seq (drop (count pre) tokens))]))

;; Write-token-string: called when buffer doesn't fit on line
(defn- write-token-string [pw tokens]
  (let [[a b] (split-at-newline tokens)]
    (when a (write-tokens pw a false))
    (when b
      (let [[section remainder] (get-section b)
            newl (first b)
            do-nl (emit-nl? newl pw section (get-sub-section b))
            result (if do-nl
                     (do (emit-nl pw newl) (next b))
                     b)
            long-section (not (tokens-fit? pw result))
            result (if long-section
                     (let [rem2 (write-token-string pw section)]
                       (if (= rem2 section)
                         (do (write-tokens pw section false) remainder)
                         (into [] (concat rem2 remainder))))
                     result)]
        result))))

(defn- write-line [pw]
  (loop [buffer (getf pw :buffer)]
    (setf pw :buffer (into [] buffer))
    (when-not (tokens-fit? pw buffer)
      (let [new-buffer (write-token-string pw buffer)]
        (when-not (identical? buffer new-buffer)
          (recur new-buffer))))))

(defn- add-to-buffer [pw token]
  (setf pw :buffer (conj (getf pw :buffer) token))
  (when-not (tokens-fit? pw (getf pw :buffer))
    (write-line pw)))

(defn- write-buffered-output [pw]
  (write-line pw)
  (when-let [buf (getf pw :buffer)]
    (when (seq buf)
      (write-tokens pw buf true)
      (setf pw :buffer []))))

(defn- write-white-space [pw]
  (when-let [tws (getf pw :trailing-white-space)]
    (pw-base-write pw tws)
    (setf pw :trailing-white-space nil)))

(defn- index-of-from [s sub start]
  (let [idx (.indexOf (subs s start) sub)]
    (if (neg? idx) -1 (+ idx start))))

(defn- split-string-newline [s]
  (loop [result [] start 0]
    (let [idx (index-of-from s "\n" start)]
      (if (neg? idx)
        (conj result (subs s start))
        (recur (conj result (subs s start idx)) (inc idx))))))

(defn- write-initial-lines [pw s]
  (let [lines (split-string-newline s)]
    (if (= (count lines) 1)
      s
      (let [prefix (:per-line-prefix (getf pw :logical-blocks))
            l (first lines)]
        (if (= :buffering (getf pw :mode))
          (let [oldpos (getf pw :pos)
                newpos (+ oldpos (count l))]
            (setf pw :pos newpos)
            (add-to-buffer pw (make-buffer-blob l nil oldpos newpos))
            (write-buffered-output pw))
          (do
            (write-white-space pw)
            (pw-base-write pw l)))
        (pw-base-write-char pw \newline)
        (doseq [l (next (butlast lines))]
          (pw-base-write pw l)
          (pw-base-write pw (pp-newline))
          (when prefix
            (pw-base-write pw prefix)))
        (setf pw :mode :writing)
        (last lines)))))

(defn- p-write-char [pw c]
  (if (= (getf pw :mode) :writing)
    (do
      (write-white-space pw)
      (pw-base-write-char pw c))
    (if (= c \newline)
      (write-initial-lines pw "\n")
      (let [oldpos (getf pw :pos)
            newpos (inc oldpos)]
        (setf pw :pos newpos)
        (add-to-buffer pw (make-buffer-blob (str c) nil oldpos newpos))))))

;; Create a pretty-writer
(defn- pretty-writer [writer max-columns miser-width]
  (let [lb (make-logical-block nil nil 0 0 false false nil nil nil)]
    (atom {:pretty-writer true
           :base (column-writer writer max-columns)
           :logical-blocks lb
           :sections nil
           :mode :writing
           :buffer []
           :buffer-block lb
           :buffer-level 1
           :miser-width miser-width
           :trailing-white-space nil
           :pos 0})))

;; Pretty-writer methods
(defn- pw-write [pw s]
  (let [s0 (write-initial-lines pw s)
        ;; Trim trailing whitespace from s0
        s-trimmed (rtrim-whitespace s0)
        white-space (subs s0 (count s-trimmed))
        mode (getf pw :mode)]
    (if (= mode :writing)
      (do
        (write-white-space pw)
        (pw-base-write pw s-trimmed)
        (setf pw :trailing-white-space white-space))
      (let [oldpos (getf pw :pos)
            newpos (+ oldpos (count s0))]
        (setf pw :pos newpos)
        (add-to-buffer pw (make-buffer-blob s-trimmed white-space oldpos newpos))))))

(defn- pw-ppflush [pw]
  (if (= (getf pw :mode) :buffering)
    (do
      (write-tokens pw (getf pw :buffer) true)
      (setf pw :buffer []))
    (write-white-space pw)))

(defn- start-block [pw prefix per-line-prefix suffix]
  (let [lb (make-logical-block (getf pw :logical-blocks) nil 0 0 false false
                               prefix per-line-prefix suffix)]
    (setf pw :logical-blocks lb)
    (if (= (getf pw :mode) :writing)
      (do
        (write-white-space pw)
        (when-let [cb (getf pw :logical-block-callback)] (cb :start))
        (when prefix (pw-base-write pw prefix))
        (let [col (get-column (getf pw :base))]
          (reset! (:start-col lb) col)
          (reset! (:indent lb) col)))
      (let [oldpos (getf pw :pos)
            newpos (+ oldpos (if prefix (count prefix) 0))]
        (setf pw :pos newpos)
        (add-to-buffer pw (make-start-block-t lb oldpos newpos))))))

(defn- end-block [pw]
  (let [lb (getf pw :logical-blocks)
        suffix (:suffix lb)]
    (if (= (getf pw :mode) :writing)
      (do
        (write-white-space pw)
        (when suffix (pw-base-write pw suffix))
        (when-let [cb (getf pw :logical-block-callback)] (cb :end)))
      (let [oldpos (getf pw :pos)
            newpos (+ oldpos (if suffix (count suffix) 0))]
        (setf pw :pos newpos)
        (add-to-buffer pw (make-end-block-t lb oldpos newpos))))
    (setf pw :logical-blocks (:parent lb))))

(defn- nl [pw type]
  (setf pw :mode :buffering)
  (let [pos (getf pw :pos)]
    (add-to-buffer pw (make-nl-t type (getf pw :logical-blocks) pos pos))))

(defn- indent [pw relative-to offset]
  (let [lb (getf pw :logical-blocks)]
    (if (= (getf pw :mode) :writing)
      (do
        (write-white-space pw)
        (reset! (:indent lb)
                (+ offset (condp = relative-to
                            :block @(:start-col lb)
                            :current (get-column (getf pw :base))))))
      (let [pos (getf pw :pos)]
        (add-to-buffer pw (make-indent-t lb relative-to offset pos pos))))))

(defn- get-miser-width [pw]
  (getf pw :miser-width))

;; Public API — cw-write for dispatch functions

(defn- cw-write
  "Write a string through the active pretty-writer, or directly to stdout."
  [s]
  (if *pw*
    (pw-write *pw* (str s))
    (print s)))

(defn- cw-write-char-out
  "Write a single character through the active pretty-writer."
  [c]
  (if *pw*
    (p-write-char *pw* c)
    (print (str c))))

;; pprint_base — public API functions

(defn- check-enumerated-arg [arg choices]
  (when-not (choices arg)
    (throw (ex-info (str "Bad argument: " arg ". Expected one of " choices)
                    {:arg arg :choices choices}))))

;; Internal tracking vars (match upstream)
(def ^:dynamic ^{:private true} *current-level* 0)
(def ^:dynamic ^{:private true} *current-length* nil)

(defn- pretty-writer? [x]
  (and (instance? clojure.lang.Atom x) (:pretty-writer @x)))

(defn- make-pretty-writer [base-writer right-margin miser-width]
  (pretty-writer base-writer right-margin miser-width))

(defn get-pretty-writer
  "Returns the pretty writer wrapped around the base writer."
  {:added "1.2"}
  [base-writer]
  (if (pretty-writer? base-writer)
    base-writer
    (make-pretty-writer base-writer *print-right-margin* *print-miser-width*)))

(defn fresh-line
  "If the output is not already at the beginning of a line, output a newline."
  {:added "1.2"}
  []
  (if *pw*
    (when (not (zero? (get-column (getf *pw* :base))))
      (cw-write "\n"))
    (println)))

(declare format-simple-number)

(defn- int-to-base-string [n base]
  (if (zero? n) "0"
      (let [neg? (neg? n)
            n (if neg? (- n) n)
            digits "0123456789abcdefghijklmnopqrstuvwxyz"]
        (loop [n n acc ""]
          (if (zero? n)
            (if neg? (str "-" acc) acc)
            (recur (quot n base)
                   (str (nth digits (rem n base)) acc)))))))

(defn- format-simple-number [x]
  (cond
    (integer? x)
    (if (or (not (= *print-base* 10)) *print-radix*)
      (let [base *print-base*
            prefix (cond (= base 2) "#b"
                         (= base 8) "#o"
                         (= base 16) "#x"
                         *print-radix* (str "#" base "r")
                         :else "")]
        ;; UPSTREAM-DIFF: pure Clojure base formatting (no Integer/toString)
        (str prefix (int-to-base-string x base)))
      nil)
    :else nil))

(def ^{:private true} write-option-table
  {:base 'clojure.pprint/*print-base*
   :circle nil  ;; not yet supported
   :length 'clojure.core/*print-length*
   :level 'clojure.core/*print-level*
   :lines nil   ;; not yet supported
   :miser-width 'clojure.pprint/*print-miser-width*
   :dispatch 'clojure.pprint/*print-pprint-dispatch*
   :pretty 'clojure.pprint/*print-pretty*
   :radix 'clojure.pprint/*print-radix*
   :readably 'clojure.core/*print-readably*
   :right-margin 'clojure.pprint/*print-right-margin*
   :suppress-namespaces 'clojure.pprint/*print-suppress-namespaces*})

(defn- table-ize [t m]
  (apply hash-map (mapcat
                   #(when-let [v (get t (key %))]
                      (when-let [var (find-var v)]
                        [var (val %)]))
                   m)))

(defmacro ^{:private true} binding-map [amap & body]
  `(do
     (push-thread-bindings ~amap)
     (try
       ~@body
       (finally
         (pop-thread-bindings)))))

(defn write-out
  "Write an object to *out* subject to the current bindings of the printer control
variables."
  {:added "1.2"}
  [object]
  (let [length-reached (and
                        *current-length*
                        *print-length*
                        (>= *current-length* *print-length*))]
    (if-not *print-pretty*
      (pr object)
      (if length-reached
        (cw-write "...")
        (do
          (when *current-length* (set! *current-length* (inc *current-length*)))
          (*print-pprint-dispatch* object))))
    length-reached))

(defn write
  "Write an object subject to the current bindings of the printer control variables.
Use the kw-args argument to override individual variables for this call (and any
recursive calls). Returns the string result if :stream is nil or nil otherwise."
  {:added "1.2"}
  [object & kw-args]
  (let [options (merge {:stream true} (apply hash-map kw-args))]
    (binding-map (table-ize write-option-table options)
                 (let [optval (if (contains? options :stream) (:stream options) true)
                       sb (when (nil? optval) (StringBuilder.))]
        ;; UPSTREAM-DIFF: CW uses *pw* binding instead of rebinding *out* to a Writer
                   (if *print-pretty*
                     (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
                       (binding [*pw* pw]
                         (write-out object))
                       (pw-ppflush pw))
                     (pr object))
        ;; TODO: when :stream is nil, capture and return string
                   (when (nil? optval)
                     nil)))))

(defn- level-exceeded []
  (and *print-level* (>= *current-level* *print-level*)))

(defn- parse-lb-options [opts body]
  (loop [body body acc []]
    (if (opts (first body))
      (recur (drop 2 body) (concat acc (take 2 body)))
      [(apply hash-map acc) body])))

(defmacro pprint-logical-block
  "Execute the body as a pretty printing logical block with output to *out* which
must be a pretty printing writer."
  {:added "1.2" :arglists '[[options* body]]}
  [& args]
  (let [[options body] (parse-lb-options #{:prefix :per-line-prefix :suffix} args)]
    `(do (if (level-exceeded)
           (cw-write "#")
           (do
             (push-thread-bindings {#'*current-level*
                                    (inc *current-level*)
                                    #'*current-length* 0})
             (try
               (when *pw*
                 (start-block *pw* ~(:prefix options) ~(:per-line-prefix options) ~(:suffix options)))
               (when-not *pw*
                 (when ~(:prefix options) (cw-write ~(:prefix options))))
               ~@body
               (when *pw*
                 (end-block *pw*))
               (when-not *pw*
                 (when ~(:suffix options) (cw-write ~(:suffix options))))
               (finally
                 (pop-thread-bindings)))))
         nil)))

(defn pprint-newline
  "Print a conditional newline to a pretty printing stream."
  {:added "1.2"}
  [kind]
  (check-enumerated-arg kind #{:linear :miser :fill :mandatory})
  (if *pw*
    (nl *pw* kind)
    (when (= kind :mandatory) (println))))

(defn pprint-indent
  "Create an indent at this point in the pretty printing stream."
  {:added "1.2"}
  [relative-to n]
  (check-enumerated-arg relative-to #{:block :current})
  (when *pw*
    (indent *pw* relative-to n)))

(defn pprint-tab
  "Tab at this point in the pretty printing stream.
THIS FUNCTION IS NOT YET IMPLEMENTED."
  {:added "1.2"}
  [kind colnum colinc]
  (check-enumerated-arg kind #{:line :section :line-relative :section-relative})
  (throw (ex-info "pprint-tab is not yet implemented" {:kind kind})))

;; Helper for dispatch functions
(defn- pll-mod-body [var-sym body]
  (letfn [(inner [form]
            (if (seq? form)
              (let [form (macroexpand form)]
                (condp = (first form)
                  'loop* form
                  'recur (concat `(recur (inc ~var-sym)) (rest form))
                  (clojure.walk/walk inner identity form)))
              form))]
    (clojure.walk/walk inner identity body)))

(defmacro print-length-loop
  "A version of loop that iterates at most *print-length* times."
  {:added "1.3"}
  [bindings & body]
  (let [count-var (gensym "length-count")
        mod-body (pll-mod-body count-var body)]
    `(loop ~(apply vector count-var 0 bindings)
       (if (or (not *print-length*) (< ~count-var *print-length*))
         (do ~@mod-body)
         (cw-write "...")))))

;; simple-dispatch — pretty print dispatch for data
;; UPSTREAM-DIFF: uses CW type predicates instead of Java class dispatch

(declare pprint-map)

(defn- pprint-simple-list [alis]
  (pprint-logical-block :prefix "(" :suffix ")"
                        (print-length-loop [alis (seq alis)]
                                           (when alis
                                             (write-out (first alis))
                                             (when (next alis)
                                               (cw-write " ")
                                               (pprint-newline :linear)
                                               (recur (next alis)))))))

(defn- pprint-list [alis]
  (let [reader-macros {'quote "'" 'clojure.core/deref "@"
                       'var "#'" 'clojure.core/unquote "~"}
        macro-char (reader-macros (first alis))]
    (if (and macro-char (= 2 (count alis)))
      (do
        (cw-write macro-char)
        (write-out (second alis)))
      (pprint-simple-list alis))))

(defn- pprint-vector [avec]
  (pprint-logical-block :prefix "[" :suffix "]"
                        (print-length-loop [aseq (seq avec)]
                                           (when aseq
                                             (write-out (first aseq))
                                             (when (next aseq)
                                               (cw-write " ")
                                               (pprint-newline :linear)
                                               (recur (next aseq)))))))

(defn- pprint-map [amap]
  ;; UPSTREAM-DIFF: skip lift-ns (CW doesn't have namespace map lifting)
  (let [prefix "{"]
    (pprint-logical-block :prefix prefix :suffix "}"
                          (print-length-loop [aseq (seq amap)]
                                             (when aseq
                                               (pprint-logical-block
                                                (write-out (ffirst aseq))
                                                (cw-write " ")
                                                (pprint-newline :linear)
                                                (set! *current-length* 0)
                                                (write-out (fnext (first aseq))))
                                               (when (next aseq)
                                                 (cw-write ", ")
                                                 (pprint-newline :linear)
                                                 (recur (next aseq))))))))

(defn- pprint-set [aset]
  (pprint-logical-block :prefix "#{" :suffix "}"
                        (print-length-loop [aseq (seq aset)]
                                           (when aseq
                                             (write-out (first aseq))
                                             (when (next aseq)
                                               (cw-write " ")
                                               (pprint-newline :linear)
                                               (recur (next aseq)))))))

(defn- pprint-simple-default [obj]
  (cond
    (and *print-suppress-namespaces* (symbol? obj)) (cw-write (name obj))
    :else (cw-write (pr-str obj))))

(defn simple-dispatch
  "The pretty print dispatch function for simple data structure format."
  {:added "1.2"}
  [object]
  (cond
    (nil? object) (cw-write (pr-str nil))
    (seq? object) (pprint-list object)
    (vector? object) (pprint-vector object)
    (map? object) (pprint-map object)
    (set? object) (pprint-set object)
    (symbol? object) (pprint-simple-default object)
    :else (pprint-simple-default object)))

(defn set-pprint-dispatch
  "Set the pretty print dispatch function to a function matching (fn [obj] ...)."
  {:added "1.2"}
  [function]
  (let [old-meta (meta #'*print-pprint-dispatch*)]
    (alter-var-root #'*print-pprint-dispatch* (constantly function))
    (alter-meta! #'*print-pprint-dispatch* (constantly old-meta)))
  nil)

;; Set simple-dispatch as the default
(set-pprint-dispatch simple-dispatch)

;; Convenience macros

(defmacro pp
  "A convenience macro that pretty prints the last thing output. This is
exactly equivalent to (pprint *1)."
  {:added "1.2"}
  [] `(pprint *1))

(defmacro with-pprint-dispatch
  "Execute body with the pretty print dispatch function bound to function."
  {:added "1.2"}
  [function & body]
  `(binding [*print-pprint-dispatch* ~function]
     ~@body))

;; print-table

(defn print-table
  "Prints a collection of maps in a textual table. Prints table headings
   ks, and then a line of output for each row, corresponding to the keys
   in ks. If ks are not specified, use the keys of the first item in rows."
  ([ks rows]
   (when (seq rows)
     (let [widths (map
                   (fn [k]
                     (apply max (count (str k)) (map #(count (str (get % k))) rows)))
                   ks)
           spacers (map #(apply str (repeat % "-")) widths)
           fmts (map #(str "%" % "s") widths)
           fmt-row (fn [leader divider trailer row]
                     (str leader
                          (apply str (interpose divider
                                                (for [[col fmt] (map vector (map #(get row %) ks) fmts)]
                                                  (format fmt (str col)))))
                          trailer))]
       (println)
       (println (fmt-row "| " " | " " |" (zipmap ks ks)))
       (println (fmt-row "|-" "-+-" "-|" (zipmap ks spacers)))
       (doseq [row rows]
         (println (fmt-row "| " " | " " |" row))))))
  ([rows] (print-table (keys (first rows)) rows)))
