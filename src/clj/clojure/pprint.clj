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

;; UPSTREAM-DIFF: Override Zig builtin pprint with Clojure implementation
;; that dispatches through *print-pprint-dispatch* (enables code-dispatch etc.)
(defn pprint
  "Pretty print object to the optional output writer. If the writer is not provided,
print the object to the currently bound value of *out*."
  {:added "1.2"}
  ([object] (pprint object *out*))
  ([object writer]
   (let [pw (make-pretty-writer writer *print-right-margin* *print-miser-width*)]
     (binding [*print-pretty* true
               *pw* pw]
       (write-out object))
     (pw-ppflush pw)
     ;; Add trailing newline
     (println))
   nil))

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
  ;; UPSTREAM-DIFF: simple-dispatch prints lists literally (no reader macro expansion).
  ;; Reader macro expansion is only in code-dispatch's pprint-code-list.
  (pprint-simple-list alis))

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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; cl-format — Common Lisp compatible format
;;; UPSTREAM-DIFF: CW port of cl_format.clj + utilities.clj
;;; Adaptations: RuntimeException→ex-info, Writer proxy→with-out-str,
;;;   .length→count, .numerator/.denominator→functions,
;;;   java.io.StringWriter→with-out-str, Math/abs→conditional negate,
;;;   format "%o"/"%x"→pure Clojure base conversion
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Forward references
(declare compile-format)
(declare execute-format)
(declare init-navigator)

;; UPSTREAM-DIFF: Character/toUpperCase and Character/toLowerCase not available in CW
;; Use string method via (first (.toUpperCase (str c))) pattern
(defn- char-upper [c] (first (.toUpperCase (str c))))
(defn- char-lower [c] (first (.toLowerCase (str c))))

;;; Utility functions (from utilities.clj)

(defn- map-passing-context [func initial-context lis]
  (loop [context initial-context
         lis lis
         acc []]
    (if (empty? lis)
      [acc context]
      (let [this (first lis)
            remainder (next lis)
            [result new-context] (apply func [this context])]
        (recur new-context remainder (conj acc result))))))

(defn- consume [func initial-context]
  (loop [context initial-context
         acc []]
    (let [[result new-context] (apply func [context])]
      (if (not result)
        [acc new-context]
        (recur new-context (conj acc result))))))

(defn- unzip-map [m]
  [(into {} (for [[k [v1 v2]] m] [k v1]))
   (into {} (for [[k [v1 v2]] m] [k v2]))])

(defn- tuple-map [m v1]
  (into {} (for [[k v] m] [k [v v1]])))

(defn- rtrim [s c]
  (let [len (count s)]
    (if (and (pos? len) (= (nth s (dec len)) c))
      (loop [n (dec len)]
        (cond
          (neg? n) ""
          (not (= (nth s n) c)) (subs s 0 (inc n))
          true (recur (dec n))))
      s)))

(defn- ltrim [s c]
  (let [len (count s)]
    (if (and (pos? len) (= (nth s 0) c))
      (loop [n 0]
        (if (or (= n len) (not (= (nth s n) c)))
          (subs s n)
          (recur (inc n))))
      s)))

(defn- prefix-count [aseq val]
  (let [test (if (coll? val) (set val) #{val})]
    (loop [pos 0]
      (if (or (= pos (count aseq)) (not (test (nth aseq pos))))
        pos
        (recur (inc pos))))))

;;; cl-format

(def ^:dynamic ^{:private true} *format-str* nil)

(defn- format-error [message offset]
  (let [full-message (str message \newline *format-str* \newline
                          (apply str (repeat offset \space)) "^" \newline)]
    (throw (ex-info full-message {:type :format-error :offset offset}))))

;;; Argument navigators

(defstruct ^{:private true}
 arg-navigator :seq :rest :pos)

(defn- init-navigator [s]
  (let [s (seq s)]
    (struct arg-navigator s s 0)))

(defn- next-arg [navigator]
  (let [rst (:rest navigator)]
    (if rst
      [(first rst) (struct arg-navigator (:seq navigator) (next rst) (inc (:pos navigator)))]
      (throw (ex-info "Not enough arguments for format definition" {:type :format-error})))))

(defn- next-arg-or-nil [navigator]
  (let [rst (:rest navigator)]
    (if rst
      [(first rst) (struct arg-navigator (:seq navigator) (next rst) (inc (:pos navigator)))]
      [nil navigator])))

(defn- get-format-arg [navigator]
  (let [[raw-format navigator] (next-arg navigator)
        compiled-format (if (string? raw-format)
                          (compile-format raw-format)
                          raw-format)]
    [compiled-format navigator]))

(declare relative-reposition)

(defn- absolute-reposition [navigator position]
  (if (>= position (:pos navigator))
    (relative-reposition navigator (- position (:pos navigator)))
    (struct arg-navigator (:seq navigator) (drop position (:seq navigator)) position)))

(defn- relative-reposition [navigator position]
  (let [newpos (+ (:pos navigator) position)]
    (if (neg? position)
      (absolute-reposition navigator newpos)
      (struct arg-navigator (:seq navigator) (drop position (:rest navigator)) newpos))))

(defstruct ^{:private true}
 compiled-directive :func :def :params :offset)

;;; Parameter realization

(defn- realize-parameter [[param [raw-val offset]] navigator]
  (let [[real-param new-navigator]
        (cond
          (contains? #{:at :colon} param)
          [raw-val navigator]

          (= raw-val :parameter-from-args)
          (next-arg navigator)

          (= raw-val :remaining-arg-count)
          [(count (:rest navigator)) navigator]

          true
          [raw-val navigator])]
    [[param [real-param offset]] new-navigator]))

(defn- realize-parameter-list [parameter-map navigator]
  (let [[pairs new-navigator]
        (map-passing-context realize-parameter navigator parameter-map)]
    [(into {} pairs) new-navigator]))

;;; Directive support functions

(declare opt-base-str)

(def ^{:private true}
  special-radix-markers {2 "#b" 8 "#o" 16 "#x"})

;; UPSTREAM-DIFF: uses numerator/denominator functions instead of .numerator/.denominator methods
(defn- format-simple-number-for-cl [n]
  (cond
    (integer? n) (if (= *print-base* 10)
                   (str n (if *print-radix* "."))
                   (str
                    (if *print-radix* (or (get special-radix-markers *print-base*) (str "#" *print-base* "r")))
                    (opt-base-str *print-base* n)))
    (ratio? n) (str
                (if *print-radix* (or (get special-radix-markers *print-base*) (str "#" *print-base* "r")))
                (opt-base-str *print-base* (numerator n))
                "/"
                (opt-base-str *print-base* (denominator n)))
    :else nil))

(defn- format-ascii [print-func params arg-navigator offsets]
  (let [[arg arg-navigator] (next-arg arg-navigator)
        ;; UPSTREAM-DIFF: CW's print-str returns "" for nil, upstream returns "nil"
        raw-output (or (format-simple-number-for-cl arg)
                       (let [s (print-func arg)] (if (and (nil? arg) (= s "")) "nil" s)))
        base-output (str raw-output)
        base-width (count base-output)
        min-width (+ base-width (:minpad params))
        width (if (>= min-width (:mincol params))
                min-width
                (+ min-width
                   (* (+ (quot (- (:mincol params) min-width 1)
                               (:colinc params))
                         1)
                      (:colinc params))))
        chars (apply str (repeat (- width base-width) (:padchar params)))]
    (if (:at params)
      (print (str chars base-output))
      (print (str base-output chars)))
    arg-navigator))

;;; Integer directives

(defn- integral? [x]
  (cond
    (integer? x) true
    (float? x) (== x (Math/floor x))
    (ratio? x) (= 0 (rem (numerator x) (denominator x)))
    :else false))

(defn- remainders [base val]
  (reverse
   (first
    (consume #(if (pos? %)
                [(rem % base) (quot % base)]
                [nil nil])
             val))))

(defn- base-str [base val]
  (if (zero? val)
    "0"
    (apply str
           (map
            #(if (< % 10) (char (+ (int \0) %)) (char (+ (int \a) (- % 10))))
            (remainders base val)))))

;; UPSTREAM-DIFF: no Java format for %o/%x, always use base-str
(defn- opt-base-str [base val]
  (base-str base val))

(defn- group-by* [unit lis]
  (reverse
   (first
    (consume (fn [x] [(seq (reverse (take unit x))) (seq (drop unit x))]) (reverse lis)))))

(defn- format-integer [base params arg-navigator offsets]
  (let [[arg arg-navigator] (next-arg arg-navigator)]
    (if (integral? arg)
      (let [neg (neg? arg)
            pos-arg (if neg (- arg) arg)
            raw-str (opt-base-str base pos-arg)
            group-str (if (:colon params)
                        (let [groups (map #(apply str %) (group-by* (:commainterval params) raw-str))
                              commas (repeat (count groups) (:commachar params))]
                          (apply str (next (interleave commas groups))))
                        raw-str)
            signed-str (cond
                         neg (str "-" group-str)
                         (:at params) (str "+" group-str)
                         true group-str)
            padded-str (if (< (count signed-str) (:mincol params))
                         (str (apply str (repeat (- (:mincol params) (count signed-str))
                                                 (:padchar params)))
                              signed-str)
                         signed-str)]
        (print padded-str))
      (format-ascii print-str {:mincol (:mincol params) :colinc 1 :minpad 0
                               :padchar (:padchar params) :at true}
                    (init-navigator [arg]) nil))
    arg-navigator))

;;; English number formats

(def ^{:private true}
  english-cardinal-units
  ["zero" "one" "two" "three" "four" "five" "six" "seven" "eight" "nine"
   "ten" "eleven" "twelve" "thirteen" "fourteen"
   "fifteen" "sixteen" "seventeen" "eighteen" "nineteen"])

(def ^{:private true}
  english-ordinal-units
  ["zeroth" "first" "second" "third" "fourth" "fifth" "sixth" "seventh" "eighth" "ninth"
   "tenth" "eleventh" "twelfth" "thirteenth" "fourteenth"
   "fifteenth" "sixteenth" "seventeenth" "eighteenth" "nineteenth"])

(def ^{:private true}
  english-cardinal-tens
  ["" "" "twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"])

(def ^{:private true}
  english-ordinal-tens
  ["" "" "twentieth" "thirtieth" "fortieth" "fiftieth"
   "sixtieth" "seventieth" "eightieth" "ninetieth"])

(def ^{:private true}
  english-scale-numbers
  ["" "thousand" "million" "billion" "trillion" "quadrillion" "quintillion"
   "sextillion" "septillion" "octillion" "nonillion" "decillion"
   "undecillion" "duodecillion" "tredecillion" "quattuordecillion"
   "quindecillion" "sexdecillion" "septendecillion"
   "octodecillion" "novemdecillion" "vigintillion"])

(defn- format-simple-cardinal [num]
  (let [hundreds (quot num 100)
        tens (rem num 100)]
    (str
     (if (pos? hundreds) (str (nth english-cardinal-units hundreds) " hundred"))
     (if (and (pos? hundreds) (pos? tens)) " ")
     (if (pos? tens)
       (if (< tens 20)
         (nth english-cardinal-units tens)
         (let [ten-digit (quot tens 10)
               unit-digit (rem tens 10)]
           (str
            (if (pos? ten-digit) (nth english-cardinal-tens ten-digit))
            (if (and (pos? ten-digit) (pos? unit-digit)) "-")
            (if (pos? unit-digit) (nth english-cardinal-units unit-digit)))))))))

(defn- add-english-scales [parts offset]
  (let [cnt (count parts)]
    (loop [acc []
           pos (dec cnt)
           this (first parts)
           remainder (next parts)]
      (if (nil? remainder)
        (str (apply str (interpose ", " acc))
             (if (and (not (empty? this)) (not (empty? acc))) ", ")
             this
             (if (and (not (empty? this)) (pos? (+ pos offset)))
               (str " " (nth english-scale-numbers (+ pos offset)))))
        (recur
         (if (empty? this)
           acc
           (conj acc (str this " " (nth english-scale-numbers (+ pos offset)))))
         (dec pos)
         (first remainder)
         (next remainder))))))

(defn- format-cardinal-english [params navigator offsets]
  (let [[arg navigator] (next-arg navigator)]
    (if (= 0 arg)
      (print "zero")
      (let [abs-arg (if (neg? arg) (- arg) arg)
            parts (remainders 1000 abs-arg)]
        (if (<= (count parts) (count english-scale-numbers))
          (let [parts-strs (map format-simple-cardinal parts)
                full-str (add-english-scales parts-strs 0)]
            (print (str (if (neg? arg) "minus ") full-str)))
          (format-integer
           10
           {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
           (init-navigator [arg])
           {:mincol 0 :padchar 0 :commachar 0 :commainterval 0}))))
    navigator))

(defn- format-simple-ordinal [num]
  (let [hundreds (quot num 100)
        tens (rem num 100)]
    (str
     (if (pos? hundreds) (str (nth english-cardinal-units hundreds) " hundred"))
     (if (and (pos? hundreds) (pos? tens)) " ")
     (if (pos? tens)
       (if (< tens 20)
         (nth english-ordinal-units tens)
         (let [ten-digit (quot tens 10)
               unit-digit (rem tens 10)]
           (if (and (pos? ten-digit) (not (pos? unit-digit)))
             (nth english-ordinal-tens ten-digit)
             (str
              (if (pos? ten-digit) (nth english-cardinal-tens ten-digit))
              (if (and (pos? ten-digit) (pos? unit-digit)) "-")
              (if (pos? unit-digit) (nth english-ordinal-units unit-digit))))))
       (if (pos? hundreds) "th")))))

(defn- format-ordinal-english [params navigator offsets]
  (let [[arg navigator] (next-arg navigator)]
    (if (= 0 arg)
      (print "zeroth")
      (let [abs-arg (if (neg? arg) (- arg) arg)
            parts (remainders 1000 abs-arg)]
        (if (<= (count parts) (count english-scale-numbers))
          (let [parts-strs (map format-simple-cardinal (drop-last parts))
                head-str (add-english-scales parts-strs 1)
                tail-str (format-simple-ordinal (last parts))]
            (print (str (if (neg? arg) "minus ")
                        (cond
                          (and (not (empty? head-str)) (not (empty? tail-str)))
                          (str head-str ", " tail-str)

                          (not (empty? head-str)) (str head-str "th")
                          :else tail-str))))
          (do (format-integer
               10
               {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
               (init-navigator [arg])
               {:mincol 0 :padchar 0 :commachar 0 :commainterval 0})
              (let [low-two-digits (rem arg 100)
                    not-teens (or (< 11 low-two-digits) (> 19 low-two-digits))
                    low-digit (rem low-two-digits 10)]
                (print (cond
                         (and (== low-digit 1) not-teens) "st"
                         (and (== low-digit 2) not-teens) "nd"
                         (and (== low-digit 3) not-teens) "rd"
                         :else "th")))))))
    navigator))

;;; Roman numeral formats

(def ^{:private true}
  old-roman-table
  [["I" "II" "III" "IIII" "V" "VI" "VII" "VIII" "VIIII"]
   ["X" "XX" "XXX" "XXXX" "L" "LX" "LXX" "LXXX" "LXXXX"]
   ["C" "CC" "CCC" "CCCC" "D" "DC" "DCC" "DCCC" "DCCCC"]
   ["M" "MM" "MMM"]])

(def ^{:private true}
  new-roman-table
  [["I" "II" "III" "IV" "V" "VI" "VII" "VIII" "IX"]
   ["X" "XX" "XXX" "XL" "L" "LX" "LXX" "LXXX" "XC"]
   ["C" "CC" "CCC" "CD" "D" "DC" "DCC" "DCCC" "CM"]
   ["M" "MM" "MMM"]])

(defn- format-roman [table params navigator offsets]
  (let [[arg navigator] (next-arg navigator)]
    (if (and (number? arg) (> arg 0) (< arg 4000))
      (let [digits (remainders 10 arg)]
        (loop [acc []
               pos (dec (count digits))
               digits digits]
          (if (empty? digits)
            (print (apply str acc))
            (let [digit (first digits)]
              (recur (if (= 0 digit)
                       acc
                       (conj acc (nth (nth table pos) (dec digit))))
                     (dec pos)
                     (next digits))))))
      (format-integer
       10
       {:mincol 0 :padchar \space :commachar \, :commainterval 3 :colon true}
       (init-navigator [arg])
       {:mincol 0 :padchar 0 :commachar 0 :commainterval 0}))
    navigator))

(defn- format-old-roman [params navigator offsets]
  (format-roman old-roman-table params navigator offsets))

(defn- format-new-roman [params navigator offsets]
  (format-roman new-roman-table params navigator offsets))

;;; Character formats

(def ^{:private true}
  special-chars {8 "Backspace" 9 "Tab" 10 "Newline" 13 "Return" 32 "Space"})

(defn- pretty-character [params navigator offsets]
  (let [[c navigator] (next-arg navigator)
        as-int (int c)
        base-char (bit-and as-int 127)
        meta (bit-and as-int 128)
        special (get special-chars base-char)]
    (if (> meta 0) (print "Meta-"))
    (print (cond
             special special
             (< base-char 32) (str "Control-" (char (+ base-char 64)))
             (= base-char 127) "Control-?"
             :else (char base-char)))
    navigator))

(defn- readable-character [params navigator offsets]
  (let [[c navigator] (next-arg navigator)]
    (condp = (:char-format params)
      \o (cl-format true "\\o~3,'0o" (int c))
      \u (cl-format true "\\u~4,'0x" (int c))
      nil (pr c))
    navigator))

(defn- plain-character [params navigator offsets]
  (let [[char navigator] (next-arg navigator)]
    (print char)
    navigator))

;;; Abort handling
(defn- abort? [context]
  (let [token (first context)]
    (or (= :up-arrow token) (= :colon-up-arrow token))))

(defn- execute-sub-format [format args base-args]
  (second
   (map-passing-context
    (fn [element context]
      (if (abort? context)
        [nil context]
        (let [[params args] (realize-parameter-list (:params element) context)
              [params offsets] (unzip-map params)
              params (assoc params :base-args base-args)]
          [nil (apply (:func element) [params args offsets])])))
    args
    format)))

;;; Float support

(defn- float-parts-base [f]
  (let [s (.toLowerCase (str f))
        exploc (.indexOf s "e")
        dotloc (.indexOf s ".")]
    (if (neg? exploc)
      (if (neg? dotloc)
        [s (str (dec (count s)))]
        [(str (subs s 0 dotloc) (subs s (inc dotloc))) (str (dec dotloc))])
      (if (neg? dotloc)
        [(subs s 0 exploc) (subs s (inc exploc))]
        [(str (subs s 0 1) (subs s 2 exploc)) (subs s (inc exploc))]))))

(defn- float-parts [f]
  (let [[m e] (float-parts-base f)
        m1 (rtrim m \0)
        m2 (ltrim m1 \0)
        delta (- (count m1) (count m2))
        e (if (and (pos? (count e)) (= (nth e 0) \+)) (subs e 1) e)]
    (if (empty? m2)
      ["0" 0]
      [m2 (- (Integer/parseInt e) delta)])))

(defn- inc-s [s]
  (let [len-1 (dec (count s))]
    (loop [i len-1]
      (cond
        (neg? i) (apply str "1" (repeat (inc len-1) "0"))
        (= \9 (.charAt ^String s i)) (recur (dec i))
        :else (apply str (subs s 0 i)
                     (char (inc (int (.charAt ^String s i))))
                     (repeat (- len-1 i) "0"))))))

(defn- round-str [m e d w]
  (if (or d w)
    (let [len (count m)
          w (if w (max 2 w))
          round-pos (cond
                      d (+ e d 1)
                      (>= e 0) (max (inc e) (dec w))
                      :else (+ w e))
          [m1 e1 round-pos len] (if (= round-pos 0)
                                  [(str "0" m) (inc e) 1 (inc len)]
                                  [m e round-pos len])]
      (if round-pos
        (if (neg? round-pos)
          ["0" 0 false]
          (if (> len round-pos)
            (let [round-char (nth m1 round-pos)
                  result (subs m1 0 round-pos)]
              (if (>= (int round-char) (int \5))
                (let [round-up-result (inc-s result)
                      expanded (> (count round-up-result) (count result))]
                  [(if expanded
                     (subs round-up-result 0 (dec (count round-up-result)))
                     round-up-result)
                   e1 expanded])
                [result e1 false]))
            [m e false]))
        [m e false]))
    [m e false]))

(defn- expand-fixed [m e d]
  (let [[m1 e1] (if (neg? e)
                  [(str (apply str (repeat (dec (- e)) \0)) m) -1]
                  [m e])
        len (count m1)
        target-len (if d (+ e1 d 1) (inc e1))]
    (if (< len target-len)
      (str m1 (apply str (repeat (- target-len len) \0)))
      m1)))

(defn- insert-decimal [m e]
  (if (neg? e)
    (str "." m)
    (let [loc (inc e)]
      (str (subs m 0 loc) "." (subs m loc)))))

(defn- get-fixed [m e d]
  (insert-decimal (expand-fixed m e d) e))

(defn- insert-scaled-decimal [m k]
  (if (neg? k)
    (str "." m)
    (str (subs m 0 k) "." (subs m k))))

;; UPSTREAM-DIFF: uses conditional negate instead of Double/POSITIVE_INFINITY
(defn- convert-ratio [x]
  (if (ratio? x)
    (let [d (double x)]
      (if (== d 0.0)
        (if (not= x 0)
          (bigdec x)
          d)
        (if (or (== d ##Inf) (== d ##-Inf))
          (bigdec x)
          d)))
    x))

(defn- fixed-float [params navigator offsets]
  (let [w (:w params)
        d (:d params)
        [arg navigator] (next-arg navigator)
        [sign abs] (if (neg? arg) ["-" (- arg)] ["+" arg])
        abs (convert-ratio abs)
        [mantissa exp] (float-parts abs)
        scaled-exp (+ exp (:k params))
        add-sign (or (:at params) (neg? arg))
        append-zero (and (not d) (<= (dec (count mantissa)) scaled-exp))
        [rounded-mantissa scaled-exp expanded] (round-str mantissa scaled-exp
                                                          d (if w (- w (if add-sign 1 0))))
        fixed-repr (get-fixed rounded-mantissa (if expanded (inc scaled-exp) scaled-exp) d)
        fixed-repr (if (and w d
                            (>= d 1)
                            (= (.charAt ^String fixed-repr 0) \0)
                            (= (.charAt ^String fixed-repr 1) \.)
                            (> (count fixed-repr) (- w (if add-sign 1 0))))
                     (subs fixed-repr 1)
                     fixed-repr)
        prepend-zero (= (first fixed-repr) \.)]
    (if w
      (let [len (count fixed-repr)
            signed-len (if add-sign (inc len) len)
            prepend-zero (and prepend-zero (not (>= signed-len w)))
            append-zero (and append-zero (not (>= signed-len w)))
            full-len (if (or prepend-zero append-zero)
                       (inc signed-len)
                       signed-len)]
        (if (and (> full-len w) (:overflowchar params))
          (print (apply str (repeat w (:overflowchar params))))
          (print (str
                  (apply str (repeat (- w full-len) (:padchar params)))
                  (if add-sign sign)
                  (if prepend-zero "0")
                  fixed-repr
                  (if append-zero "0")))))
      (print (str
              (if add-sign sign)
              (if prepend-zero "0")
              fixed-repr
              (if append-zero "0"))))
    navigator))

;; UPSTREAM-DIFF: uses (if (neg? arg) (- arg) arg) instead of Math/abs
(defn- exponential-float [params navigator offsets]
  (let [[arg navigator] (next-arg navigator)
        arg (convert-ratio arg)]
    (loop [[mantissa exp] (float-parts (if (neg? arg) (- arg) arg))]
      (let [w (:w params)
            d (:d params)
            e (:e params)
            k (:k params)
            expchar (or (:exponentchar params) \E)
            add-sign (or (:at params) (neg? arg))
            prepend-zero (<= k 0)
            scaled-exp (- exp (dec k))
            scaled-exp-abs (if (neg? scaled-exp) (- scaled-exp) scaled-exp)
            scaled-exp-str (str scaled-exp-abs)
            scaled-exp-str (str expchar (if (neg? scaled-exp) \- \+)
                                (if e (apply str
                                             (repeat
                                              (- e
                                                 (count scaled-exp-str))
                                              \0)))
                                scaled-exp-str)
            exp-width (count scaled-exp-str)
            base-mantissa-width (count mantissa)
            scaled-mantissa (str (apply str (repeat (- k) \0))
                                 mantissa
                                 (if d
                                   (apply str
                                          (repeat
                                           (- d (dec base-mantissa-width)
                                              (if (neg? k) (- k) 0)) \0))))
            w-mantissa (if w (- w exp-width))
            [rounded-mantissa _ incr-exp] (round-str
                                           scaled-mantissa 0
                                           (cond
                                             (= k 0) (dec d)
                                             (pos? k) d
                                             (neg? k) (dec d))
                                           (if w-mantissa
                                             (- w-mantissa (if add-sign 1 0))))
            full-mantissa (insert-scaled-decimal rounded-mantissa k)
            append-zero (and (= k (count rounded-mantissa)) (nil? d))]
        (if (not incr-exp)
          (if w
            (let [len (+ (count full-mantissa) exp-width)
                  signed-len (if add-sign (inc len) len)
                  prepend-zero (and prepend-zero (not (= signed-len w)))
                  full-len (if prepend-zero (inc signed-len) signed-len)
                  append-zero (and append-zero (< full-len w))]
              (if (and (or (> full-len w) (and e (> (- exp-width 2) e)))
                       (:overflowchar params))
                (print (apply str (repeat w (:overflowchar params))))
                (print (str
                        (apply str
                               (repeat
                                (- w full-len (if append-zero 1 0))
                                (:padchar params)))
                        (if add-sign (if (neg? arg) \- \+))
                        (if prepend-zero "0")
                        full-mantissa
                        (if append-zero "0")
                        scaled-exp-str))))
            (print (str
                    (if add-sign (if (neg? arg) \- \+))
                    (if prepend-zero "0")
                    full-mantissa
                    (if append-zero "0")
                    scaled-exp-str)))
          (recur [rounded-mantissa (inc exp)]))))
    navigator))

(defn- general-float [params navigator offsets]
  (let [[arg _] (next-arg navigator)
        arg (convert-ratio arg)
        [mantissa exp] (float-parts (if (neg? arg) (- arg) arg))
        w (:w params)
        d (:d params)
        e (:e params)
        n (if (= arg 0.0) 0 (inc exp))
        ee (if e (+ e 2) 4)
        ww (if w (- w ee))
        d (if d d (max (count mantissa) (min n 7)))
        dd (- d n)]
    (if (<= 0 dd d)
      (let [navigator (fixed-float {:w ww :d dd :k 0
                                    :overflowchar (:overflowchar params)
                                    :padchar (:padchar params) :at (:at params)}
                                   navigator offsets)]
        (print (apply str (repeat ee \space)))
        navigator)
      (exponential-float params navigator offsets))))

;; UPSTREAM-DIFF: uses (if (neg? arg) (- arg) arg) instead of Math/abs
(defn- dollar-float [params navigator offsets]
  (let [[arg navigator] (next-arg navigator)
        [mantissa exp] (float-parts (if (neg? arg) (- arg) arg))
        d (:d params)
        n (:n params)
        w (:w params)
        add-sign (or (:at params) (neg? arg))
        [rounded-mantissa scaled-exp expanded] (round-str mantissa exp d nil)
        fixed-repr (get-fixed rounded-mantissa (if expanded (inc scaled-exp) scaled-exp) d)
        full-repr (str (apply str (repeat (- n (.indexOf ^String fixed-repr ".")) \0)) fixed-repr)
        full-len (+ (count full-repr) (if add-sign 1 0))]
    (print (str
            (if (and (:colon params) add-sign) (if (neg? arg) \- \+))
            (apply str (repeat (- w full-len) (:padchar params)))
            (if (and (not (:colon params)) add-sign) (if (neg? arg) \- \+))
            full-repr))
    navigator))

;;; Conditional constructs

(defn- choice-conditional [params arg-navigator offsets]
  (let [arg (:selector params)
        [arg navigator] (if arg [arg arg-navigator] (next-arg arg-navigator))
        clauses (:clauses params)
        clause (if (or (neg? arg) (>= arg (count clauses)))
                 (first (:else params))
                 (nth clauses arg))]
    (if clause
      (execute-sub-format clause navigator (:base-args params))
      navigator)))

(defn- boolean-conditional [params arg-navigator offsets]
  (let [[arg navigator] (next-arg arg-navigator)
        clauses (:clauses params)
        clause (if arg
                 (second clauses)
                 (first clauses))]
    (if clause
      (execute-sub-format clause navigator (:base-args params))
      navigator)))

(defn- check-arg-conditional [params arg-navigator offsets]
  (let [[arg navigator] (next-arg arg-navigator)
        clauses (:clauses params)
        clause (if arg (first clauses))]
    (if arg
      (if clause
        (execute-sub-format clause arg-navigator (:base-args params))
        arg-navigator)
      navigator)))

;;; Iteration constructs

(defn- iterate-sublist [params navigator offsets]
  (let [max-count (:max-iterations params)
        param-clause (first (:clauses params))
        [clause navigator] (if (empty? param-clause)
                             (get-format-arg navigator)
                             [param-clause navigator])
        [arg-list navigator] (next-arg navigator)
        args (init-navigator arg-list)]
    (loop [count 0
           args args
           last-pos -1]
      (if (and (not max-count) (= (:pos args) last-pos) (> count 1))
        (throw (ex-info "%{ construct not consuming any arguments: Infinite loop!" {:type :format-error})))
      (if (or (and (empty? (:rest args))
                   (or (not (:colon (:right-params params))) (> count 0)))
              (and max-count (>= count max-count)))
        navigator
        (let [iter-result (execute-sub-format clause args (:base-args params))]
          (if (= :up-arrow (first iter-result))
            navigator
            (recur (inc count) iter-result (:pos args))))))))

(defn- iterate-list-of-sublists [params navigator offsets]
  (let [max-count (:max-iterations params)
        param-clause (first (:clauses params))
        [clause navigator] (if (empty? param-clause)
                             (get-format-arg navigator)
                             [param-clause navigator])
        [arg-list navigator] (next-arg navigator)]
    (loop [count 0
           arg-list arg-list]
      (if (or (and (empty? arg-list)
                   (or (not (:colon (:right-params params))) (> count 0)))
              (and max-count (>= count max-count)))
        navigator
        (let [iter-result (execute-sub-format
                           clause
                           (init-navigator (first arg-list))
                           (init-navigator (next arg-list)))]
          (if (= :colon-up-arrow (first iter-result))
            navigator
            (recur (inc count) (next arg-list))))))))

(defn- iterate-main-list [params navigator offsets]
  (let [max-count (:max-iterations params)
        param-clause (first (:clauses params))
        [clause navigator] (if (empty? param-clause)
                             (get-format-arg navigator)
                             [param-clause navigator])]
    (loop [count 0
           navigator navigator
           last-pos -1]
      (if (and (not max-count) (= (:pos navigator) last-pos) (> count 1))
        (throw (ex-info "%@{ construct not consuming any arguments: Infinite loop!" {:type :format-error})))
      (if (or (and (empty? (:rest navigator))
                   (or (not (:colon (:right-params params))) (> count 0)))
              (and max-count (>= count max-count)))
        navigator
        (let [iter-result (execute-sub-format clause navigator (:base-args params))]
          (if (= :up-arrow (first iter-result))
            (second iter-result)
            (recur
             (inc count) iter-result (:pos navigator))))))))

(defn- iterate-main-sublists [params navigator offsets]
  (let [max-count (:max-iterations params)
        param-clause (first (:clauses params))
        [clause navigator] (if (empty? param-clause)
                             (get-format-arg navigator)
                             [param-clause navigator])]
    (loop [count 0
           navigator navigator]
      (if (or (and (empty? (:rest navigator))
                   (or (not (:colon (:right-params params))) (> count 0)))
              (and max-count (>= count max-count)))
        navigator
        (let [[sublist navigator] (next-arg-or-nil navigator)
              iter-result (execute-sub-format clause (init-navigator sublist) navigator)]
          (if (= :colon-up-arrow (first iter-result))
            navigator
            (recur (inc count) navigator)))))))

;;; Logical block and justification for ~<...~>

(declare format-logical-block)
(declare justify-clauses)

(defn- logical-block-or-justify [params navigator offsets]
  (if (:colon (:right-params params))
    (format-logical-block params navigator offsets)
    (justify-clauses params navigator offsets)))

;; UPSTREAM-DIFF: uses with-out-str instead of java.io.StringWriter binding
;; UPSTREAM-DIFF: uses atom + with-out-str instead of java.io.StringWriter binding
(defn- render-clauses [clauses navigator base-navigator]
  (loop [clauses clauses
         acc []
         navigator navigator]
    (if (empty? clauses)
      [acc navigator]
      (let [clause (first clauses)
            iter-atom (atom nil)
            result-str (with-out-str
                         (reset! iter-atom (execute-sub-format clause navigator base-navigator)))
            iter-result @iter-atom]
        (if (= :up-arrow (first iter-result))
          [acc (second iter-result)]
          (recur (next clauses) (conj acc result-str) iter-result))))))

(defn- justify-clauses [params navigator offsets]
  (let [[[eol-str] new-navigator] (when-let [else (:else params)]
                                    (render-clauses else navigator (:base-args params)))
        navigator (or new-navigator navigator)
        [else-params new-navigator] (when-let [p (:else-params params)]
                                      (realize-parameter-list p navigator))
        navigator (or new-navigator navigator)
        min-remaining (or (first (:min-remaining else-params)) 0)
        max-columns (or (first (:max-columns else-params))
                        (if *pw* (get-max-column (getf *pw* :base)) 72))
        clauses (:clauses params)
        [strs navigator] (render-clauses clauses navigator (:base-args params))
        slots (max 1
                   (+ (dec (count strs)) (if (:colon params) 1 0) (if (:at params) 1 0)))
        chars (reduce + (map count strs))
        mincol (:mincol params)
        minpad (:minpad params)
        colinc (:colinc params)
        minout (+ chars (* slots minpad))
        result-columns (if (<= minout mincol)
                         mincol
                         (+ mincol (* colinc
                                      (+ 1 (quot (- minout mincol 1) colinc)))))
        total-pad (- result-columns chars)
        pad (max minpad (quot total-pad slots))
        extra-pad (- total-pad (* pad slots))
        pad-str (apply str (repeat pad (:padchar params)))]
    (if (and eol-str
             (> (+ (if *pw* (get-column (getf *pw* :base)) 0) min-remaining result-columns)
                max-columns))
      (print eol-str))
    (loop [slots slots
           extra-pad extra-pad
           strs strs
           pad-only (or (:colon params)
                        (and (= (count strs) 1) (not (:at params))))]
      (if (seq strs)
        (do
          (print (str (if (not pad-only) (first strs))
                      (if (or pad-only (next strs) (:at params)) pad-str)
                      (if (pos? extra-pad) (:padchar params))))
          (recur
           (dec slots)
           (dec extra-pad)
           (if pad-only strs (next strs))
           false))))
    navigator))

;;; Case modification with ~(...~)
;; UPSTREAM-DIFF: uses with-out-str + string transforms instead of Java Writer proxies

(defn- capitalize-string [s first?]
  (let [f (first s)
        s (if (and first? f (Character/isLetter ^Character f))
            (str (char-upper f) (subs s 1))
            s)]
    (loop [result "" remaining s in-word? (and first? f (Character/isLetter ^Character f))]
      (if (empty? remaining)
        result
        (let [c (first remaining)]
          (if (Character/isWhitespace ^Character c)
            (recur (str result c) (subs remaining 1) false)
            (if in-word?
              (recur (str result c) (subs remaining 1) true)
              (recur (str result (char-upper c)) (subs remaining 1) true))))))))

;; UPSTREAM-DIFF: capture output + navigator in single execution using atom
(defn- modify-case [make-transform params navigator offsets]
  (let [clause (first (:clauses params))
        nav-result (atom nil)
        result-str (with-out-str
                     (reset! nav-result (execute-sub-format clause navigator (:base-args params))))
        transformed (make-transform result-str)]
    (print transformed)
    @nav-result))

;;; Pretty printer support from format

(defn- format-logical-block [params navigator offsets]
  (let [clauses (:clauses params)
        clause-count (count clauses)
        prefix (cond
                 (> clause-count 1) (:string (:params (first (first clauses))))
                 (:colon params) "(")
        body (nth clauses (if (> clause-count 1) 1 0))
        suffix (cond
                 (> clause-count 2) (:string (:params (first (nth clauses 2))))
                 (:colon params) ")")
        [arg navigator] (next-arg navigator)]
    (pprint-logical-block :prefix prefix :suffix suffix
                          (execute-sub-format
                           body
                           (init-navigator arg)
                           (:base-args params)))
    navigator))

(defn- set-indent [params navigator offsets]
  (let [relative-to (if (:colon params) :current :block)]
    (pprint-indent relative-to (:n params))
    navigator))

(defn- conditional-newline [params navigator offsets]
  (let [kind (if (:colon params)
               (if (:at params) :mandatory :fill)
               (if (:at params) :miser :linear))]
    (pprint-newline kind)
    navigator))

;;; Column-aware operations

;; UPSTREAM-DIFF: uses *pw* column tracking instead of *out* column tracking
(defn- absolute-tabulation [params navigator offsets]
  (let [colnum (:colnum params)
        colinc (:colinc params)
        current (if *pw* (get-column (getf *pw* :base)) 0)
        space-count (cond
                      (< current colnum) (- colnum current)
                      (= colinc 0) 0
                      :else (- colinc (rem (- current colnum) colinc)))]
    (print (apply str (repeat space-count \space))))
  navigator)

(defn- relative-tabulation [params navigator offsets]
  (let [colrel (:colnum params)
        colinc (:colinc params)
        start-col (+ colrel (if *pw* (get-column (getf *pw* :base)) 0))
        offset (if (pos? colinc) (rem start-col colinc) 0)
        space-count (+ colrel (if (= 0 offset) 0 (- colinc offset)))]
    (print (apply str (repeat space-count \space))))
  navigator)

;;; Directive table

(defn- process-directive-table-element [[char params flags bracket-info & generator-fn]]
  [char,
   {:directive char,
    :params `(array-map ~@params),
    :flags flags,
    :bracket-info bracket-info,
    :generator-fn (concat '(fn [params offset]) generator-fn)}])

(defmacro ^{:private true}
  defdirectives
  [& directives]
  `(def ^{:private true}
     directive-table (hash-map ~@(mapcat process-directive-table-element directives))))

(defdirectives
  (\A
   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
   #{:at :colon :both} {}
   #(format-ascii print-str %1 %2 %3))

  (\S
   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
   #{:at :colon :both} {}
   #(format-ascii pr-str %1 %2 %3))

  (\D
   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    :commainterval [3 Integer]]
   #{:at :colon :both} {}
   #(format-integer 10 %1 %2 %3))

  (\B
   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    :commainterval [3 Integer]]
   #{:at :colon :both} {}
   #(format-integer 2 %1 %2 %3))

  (\O
   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    :commainterval [3 Integer]]
   #{:at :colon :both} {}
   #(format-integer 8 %1 %2 %3))

  (\X
   [:mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    :commainterval [3 Integer]]
   #{:at :colon :both} {}
   #(format-integer 16 %1 %2 %3))

  (\R
   [:base [nil Integer] :mincol [0 Integer] :padchar [\space Character] :commachar [\, Character]
    :commainterval [3 Integer]]
   #{:at :colon :both} {}
   (do
     (cond
       (first (:base params))     #(format-integer (:base %1) %1 %2 %3)
       (and (:at params) (:colon params))   #(format-old-roman %1 %2 %3)
       (:at params)               #(format-new-roman %1 %2 %3)
       (:colon params)            #(format-ordinal-english %1 %2 %3)
       true                       #(format-cardinal-english %1 %2 %3))))

  (\P
   []
   #{:at :colon :both} {}
   (fn [params navigator offsets]
     (let [navigator (if (:colon params) (relative-reposition navigator -1) navigator)
           strs (if (:at params) ["y" "ies"] ["" "s"])
           [arg navigator] (next-arg navigator)]
       (print (if (= arg 1) (first strs) (second strs)))
       navigator)))

  (\C
   [:char-format [nil Character]]
   #{:at :colon :both} {}
   (cond
     (:colon params) pretty-character
     (:at params) readable-character
     :else plain-character))

  (\F
   [:w [nil Integer] :d [nil Integer] :k [0 Integer] :overflowchar [nil Character]
    :padchar [\space Character]]
   #{:at} {}
   fixed-float)

  (\E
   [:w [nil Integer] :d [nil Integer] :e [nil Integer] :k [1 Integer]
    :overflowchar [nil Character] :padchar [\space Character]
    :exponentchar [nil Character]]
   #{:at} {}
   exponential-float)

  (\G
   [:w [nil Integer] :d [nil Integer] :e [nil Integer] :k [1 Integer]
    :overflowchar [nil Character] :padchar [\space Character]
    :exponentchar [nil Character]]
   #{:at} {}
   general-float)

  (\$
   [:d [2 Integer] :n [1 Integer] :w [0 Integer] :padchar [\space Character]]
   #{:at :colon :both} {}
   dollar-float)

  (\%
   [:count [1 Integer]]
   #{} {}
   (fn [params arg-navigator offsets]
     (dotimes [i (:count params)]
       (prn))
     arg-navigator))

  (\&
   [:count [1 Integer]]
   #{:pretty} {}
   (fn [params arg-navigator offsets]
     (let [cnt (:count params)]
       (if (pos? cnt) (fresh-line))
       (dotimes [i (dec cnt)]
         (prn)))
     arg-navigator))

  (\|
   [:count [1 Integer]]
   #{} {}
   (fn [params arg-navigator offsets]
     (dotimes [i (:count params)]
       (print \formfeed))
     arg-navigator))

  (\~
   [:n [1 Integer]]
   #{} {}
   (fn [params arg-navigator offsets]
     (let [n (:n params)]
       (print (apply str (repeat n \~)))
       arg-navigator)))

  (\newline
   []
   #{:colon :at} {}
   (fn [params arg-navigator offsets]
     (if (:at params)
       (prn))
     arg-navigator))

  (\T
   [:colnum [1 Integer] :colinc [1 Integer]]
   #{:at :pretty} {}
   (if (:at params)
     #(relative-tabulation %1 %2 %3)
     #(absolute-tabulation %1 %2 %3)))

  (\*
   [:n [nil Integer]]
   #{:colon :at} {}
   (if (:at params)
     (fn [params navigator offsets]
       (let [n (or (:n params) 0)]
         (absolute-reposition navigator n)))
     (fn [params navigator offsets]
       (let [n (or (:n params) 1)]
         (relative-reposition navigator (if (:colon params) (- n) n))))))

  (\?
   []
   #{:at} {}
   (if (:at params)
     (fn [params navigator offsets]
       (let [[subformat navigator] (get-format-arg navigator)]
         (execute-sub-format subformat navigator (:base-args params))))
     (fn [params navigator offsets]
       (let [[subformat navigator] (get-format-arg navigator)
             [subargs navigator] (next-arg navigator)
             sub-navigator (init-navigator subargs)]
         (execute-sub-format subformat sub-navigator (:base-args params))
         navigator))))

  (\(
   []
   #{:colon :at :both} {:right \) :allows-separator nil :else nil}
   (let [mod-case-writer (cond
                           (and (:at params) (:colon params))
                           (fn [s] (.toUpperCase ^String s))

                           (:colon params)
                           (fn [s] (capitalize-string (.toLowerCase ^String s) true))

                           (:at params)
                           (fn [s]
                             (let [low (.toLowerCase ^String s)
                                   m (re-find #"\S" low)]
                               (if m
                                 (let [idx (.indexOf ^String low ^String m)]
                                   (str (subs low 0 idx)
                                        (char-upper (nth low idx))
                                        (subs low (inc idx))))
                                 low)))

                           :else
                           (fn [s] (.toLowerCase ^String s)))]
     #(modify-case mod-case-writer %1 %2 %3)))

  (\) [] #{} {} nil)

  (\[
   [:selector [nil Integer]]
   #{:colon :at} {:right \] :allows-separator true :else :last}
   (cond
     (:colon params)
     boolean-conditional

     (:at params)
     check-arg-conditional

     true
     choice-conditional))

  (\; [:min-remaining [nil Integer] :max-columns [nil Integer]]
      #{:colon} {:separator true} nil)

  (\] [] #{} {} nil)

  (\{
   [:max-iterations [nil Integer]]
   #{:colon :at :both} {:right \} :allows-separator false}
   (cond
     (and (:at params) (:colon params))
     iterate-main-sublists

     (:colon params)
     iterate-list-of-sublists

     (:at params)
     iterate-main-list

     true
     iterate-sublist))

  (\} [] #{:colon} {} nil)

  (\<
   [:mincol [0 Integer] :colinc [1 Integer] :minpad [0 Integer] :padchar [\space Character]]
   #{:colon :at :both :pretty} {:right \> :allows-separator true :else :first}
   logical-block-or-justify)

  (\> [] #{:colon} {} nil)

  (\^ [:arg1 [nil Integer] :arg2 [nil Integer] :arg3 [nil Integer]]
      #{:colon} {}
      (fn [params navigator offsets]
        (let [arg1 (:arg1 params)
              arg2 (:arg2 params)
              arg3 (:arg3 params)
              exit (if (:colon params) :colon-up-arrow :up-arrow)]
          (cond
            (and arg1 arg2 arg3)
            (if (<= arg1 arg2 arg3) [exit navigator] navigator)

            (and arg1 arg2)
            (if (= arg1 arg2) [exit navigator] navigator)

            arg1
            (if (= arg1 0) [exit navigator] navigator)

            true
            (if (if (:colon params)
                  (empty? (:rest (:base-args params)))
                  (empty? (:rest navigator)))
              [exit navigator] navigator)))))

  (\W
   []
   #{:at :colon :both :pretty} {}
   (if (or (:at params) (:colon params))
     (let [bindings (concat
                     (if (:at params) [:level nil :length nil] [])
                     (if (:colon params) [:pretty true] []))]
       (fn [params navigator offsets]
         (let [[arg navigator] (next-arg navigator)]
           (if (apply write arg bindings)
             [:up-arrow navigator]
             navigator))))
     (fn [params navigator offsets]
       (let [[arg navigator] (next-arg navigator)]
         (if (write-out arg)
           [:up-arrow navigator]
           navigator)))))

  (\_
   []
   #{:at :colon :both} {}
   conditional-newline)

  (\I
   [:n [0 Integer]]
   #{:colon} {}
   set-indent))

;;; Parameter parsing and compilation

(def ^{:private true}
  param-pattern #"^([vV]|#|('.)|([+-]?\d+)|(?=,))")

(def ^{:private true}
  special-params #{:parameter-from-args :remaining-arg-count})

(defn- extract-param [[s offset saw-comma]]
  (let [m (re-matcher param-pattern s)
        param (re-find m)]
    (if param
      (let [token-str (first (re-groups m))
            remainder (subs s (count token-str))
            new-offset (+ offset (count token-str))]
        (if (not (= \, (nth remainder 0)))
          [[token-str offset] [remainder new-offset false]]
          [[token-str offset] [(subs remainder 1) (inc new-offset) true]]))
      (if saw-comma
        (format-error "Badly formed parameters in format directive" offset)
        [nil [s offset]]))))

(defn- extract-params [s offset]
  (consume extract-param [s offset false]))

(defn- translate-param [[p offset]]
  [(cond
     (= (count p) 0) nil
     (and (= (count p) 1) (contains? #{\v \V} (nth p 0))) :parameter-from-args
     (and (= (count p) 1) (= \# (nth p 0))) :remaining-arg-count
     (and (= (count p) 2) (= \' (nth p 0))) (nth p 1)
     true (Integer/parseInt p))
   offset])

(def ^{:private true}
  flag-defs {\: :colon \@ :at})

(defn- extract-flags [s offset]
  (consume
   (fn [[s offset flags]]
     (if (empty? s)
       [nil [s offset flags]]
       (let [flag (get flag-defs (first s))]
         (if flag
           (if (contains? flags flag)
             (format-error
              (str "Flag \"" (first s) "\" appears more than once in a directive")
              offset)
             [true [(subs s 1) (inc offset) (assoc flags flag [true offset])]])
           [nil [s offset flags]]))))
   [s offset {}]))

;; UPSTREAM-DIFF: use (contains? allowed :x) instead of (:x allowed) — CW keyword-as-fn on sets returns nil
(defn- check-flags [def flags]
  (let [allowed (:flags def)]
    (if (and (not (contains? allowed :at)) (:at flags))
      (format-error (str "\"@\" is an illegal flag for format directive \"" (:directive def) "\"")
                    (nth (:at flags) 1)))
    (if (and (not (contains? allowed :colon)) (:colon flags))
      (format-error (str "\":\" is an illegal flag for format directive \"" (:directive def) "\"")
                    (nth (:colon flags) 1)))
    (if (and (not (contains? allowed :both)) (:at flags) (:colon flags))
      (format-error (str "Cannot combine \"@\" and \":\" flags for format directive \""
                         (:directive def) "\"")
                    (min (nth (:colon flags) 1) (nth (:at flags) 1))))))

(defn- map-params [def params flags offset]
  (check-flags def flags)
  (if (> (count params) (count (:params def)))
    (format-error
     (cl-format
      nil
      "Too many parameters for directive \"~C\": ~D~:* ~[were~;was~:;were~] specified but only ~D~:* ~[are~;is~:;are~] allowed"
      (:directive def) (count params) (count (:params def)))
     (second (first params))))
  ;; UPSTREAM-DIFF: CW can't use (instance? <retrieved-symbol> val) from data structures
  ;; Use type-name based check instead
  (doall
   (map #(let [val (first %1)
               type-sym (second (second %2))]
           (if (not (or (nil? val) (contains? special-params val)
                        (cond
                          (= type-sym 'Integer) (integer? val)
                          (= type-sym 'Character) (char? val)
                          :else true)))
             (format-error (str "Parameter " (name (first %2))
                                " has bad type in directive \"" (:directive def) "\": "
                                (class val))
                           (second %1))))
        params (:params def)))

  (merge
   (into (array-map)
         (reverse (for [[name [default]] (:params def)] [name [default offset]])))
   (reduce #(apply assoc %1 %2) {} (filter #(first (nth % 1)) (zipmap (keys (:params def)) params)))
   flags))

(defn- compile-directive [s offset]
  (let [[raw-params [rest offset]] (extract-params s offset)
        [_ [rest offset flags]] (extract-flags rest offset)
        directive (first rest)
        def (get directive-table (char-upper directive))
        params (if def (map-params def (map translate-param raw-params) flags offset))]
    (if (not directive)
      (format-error "Format string ended in the middle of a directive" offset))
    (if (not def)
      (format-error (str "Directive \"" directive "\" is undefined") offset))
    [(struct compiled-directive ((:generator-fn def) params offset) def params offset)
     (let [remainder (subs rest 1)
           offset (inc offset)
           trim? (and (= \newline (:directive def))
                      (not (:colon params)))
           trim-count (if trim? (prefix-count remainder [\space \tab]) 0)
           remainder (subs remainder trim-count)
           offset (+ offset trim-count)]
       [remainder offset])]))

(defn- compile-raw-string [s offset]
  ;; UPSTREAM-DIFF: use cw-write instead of print to route through *pw* pretty-writer
  (struct compiled-directive (fn [_ a _] (cw-write s) a) nil {:string s} offset))

(defn- right-bracket [this] (:right (:bracket-info (:def this))))
(defn- separator? [this] (:separator (:bracket-info (:def this))))
(defn- else-separator? [this]
  (and (:separator (:bracket-info (:def this)))
       (:colon (:params this))))

(declare collect-clauses)

(defn- process-bracket [this remainder]
  (let [[subex remainder] (collect-clauses (:bracket-info (:def this))
                                           (:offset this) remainder)]
    [(struct compiled-directive
             (:func this) (:def this)
             (merge (:params this) (tuple-map subex (:offset this)))
             (:offset this))
     remainder]))

(defn- process-clause [bracket-info offset remainder]
  (consume
   (fn [remainder]
     (if (empty? remainder)
       (format-error "No closing bracket found." offset)
       (let [this (first remainder)
             remainder (next remainder)]
         (cond
           (right-bracket this)
           (process-bracket this remainder)

           (= (:right bracket-info) (:directive (:def this)))
           [nil [:right-bracket (:params this) nil remainder]]

           (else-separator? this)
           [nil [:else nil (:params this) remainder]]

           (separator? this)
           [nil [:separator nil nil remainder]]

           true
           [this remainder]))))
   remainder))

(defn- collect-clauses [bracket-info offset remainder]
  (second
   (consume
    (fn [[clause-map saw-else remainder]]
      (let [[clause [type right-params else-params remainder]]
            (process-clause bracket-info offset remainder)]
        (cond
          (= type :right-bracket)
          [nil [(merge-with into clause-map
                            {(if saw-else :else :clauses) [clause]
                             :right-params right-params})
                remainder]]

          (= type :else)
          (cond
            (:else clause-map)
            (format-error "Two else clauses (\"~:;\") inside bracket construction." offset)

            (not (:else bracket-info))
            (format-error "An else clause (\"~:;\") is in a bracket type that doesn't support it."
                          offset)

            (and (= :first (:else bracket-info)) (seq (:clauses clause-map)))
            (format-error
             "The else clause (\"~:;\") is only allowed in the first position for this directive."
             offset)

            true
            (if (= :first (:else bracket-info))
              [true [(merge-with into clause-map {:else [clause] :else-params else-params})
                     false remainder]]
              [true [(merge-with into clause-map {:clauses [clause]})
                     true remainder]]))

          (= type :separator)
          (cond
            saw-else
            (format-error "A plain clause (with \"~;\") follows an else clause (\"~:;\") inside bracket construction." offset)

            (not (:allows-separator bracket-info))
            (format-error "A separator (\"~;\") is in a bracket type that doesn't support it."
                          offset)

            true
            [true [(merge-with into clause-map {:clauses [clause]})
                   false remainder]]))))
    [{:clauses []} false remainder])))

(defn- process-nesting [format]
  (first
   (consume
    (fn [remainder]
      (let [this (first remainder)
            remainder (next remainder)
            bracket (:bracket-info (:def this))]
        (if (:right bracket)
          (process-bracket this remainder)
          [this remainder])))
    format)))

(defn- compile-format [format-str]
  (binding [*format-str* format-str]
    (process-nesting
     (first
      (consume
       (fn [[s offset]]
         (if (empty? s)
           [nil s]
           (let [tilde (.indexOf ^String s "~")]
             (cond
               (neg? tilde) [(compile-raw-string s offset) ["" (+ offset (count s))]]
               (zero? tilde) (compile-directive (subs s 1) (inc offset))
               true
               [(compile-raw-string (subs s 0 tilde) offset) [(subs s tilde) (+ tilde offset)]]))))
       [format-str 0])))))

(defn- needs-pretty [format]
  (loop [format format]
    (if (empty? format)
      false
      (if (or (:pretty (:flags (:def (first format))))
              (some needs-pretty (first (:clauses (:params (first format)))))
              (some needs-pretty (first (:else (:params (first format))))))
        true
        (recur (next format))))))

;; UPSTREAM-DIFF: CW uses *pw* pretty-writer binding instead of *out* Writer rebinding
(defn- execute-format
  ([stream format args]
   (let [sb (if (not stream) true nil)]
     (if sb
       ;; output to string
       (with-out-str
         (if (and (needs-pretty format) *print-pretty*)
           (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
             (binding [*pw* pw]
               (execute-format format args))
             (pw-ppflush pw))
           (execute-format format args)))
       ;; output to *out* (stream is true or a writer)
       (do
         (if (and (needs-pretty format) *print-pretty*)
           (let [pw (make-pretty-writer nil *print-right-margin* *print-miser-width*)]
             (binding [*pw* pw]
               (execute-format format args))
             (pw-ppflush pw))
           (execute-format format args))
         nil))))
  ([format args]
   (map-passing-context
    (fn [element context]
      (if (abort? context)
        [nil context]
        (let [[params args] (realize-parameter-list
                             (:params element) context)
              [params offsets] (unzip-map params)
              params (assoc params :base-args args)]
          [nil (apply (:func element) [params args offsets])])))
    args
    format)
   nil))

(def ^{:private true} cached-compile (memoize compile-format))

(defn cl-format
  "An implementation of a Common Lisp compatible format function. cl-format formats its
arguments to an output stream or string based on the format control string given. It
supports sophisticated formatting of structured data.

Writer is an instance of java.io.Writer, true to output to *out* or nil to output
to a string, format-in is the format control string and the remaining arguments
are the data to be formatted.

The format control string is a string to be output with embedded 'format directives'
describing how to format the various arguments passed in.

If writer is nil, cl-format returns the formatted result string. Otherwise, cl-format
returns nil."
  {:added "1.2"}
  [writer format-in & args]
  (let [compiled-format (if (string? format-in) (compile-format format-in) format-in)
        navigator (init-navigator args)]
    (execute-format writer compiled-format navigator)))

(defmacro formatter
  "Makes a function which can directly run format-in. The function is
fn [stream & args] ... and returns nil unless the stream is nil (meaning
output to a string) in which case it returns the resulting string.

format-in can be either a control string or a previously compiled format."
  {:added "1.2"}
  [format-in]
  `(let [format-in# ~format-in
         ;; UPSTREAM-DIFF: direct fn refs instead of ns-interns lookup
         my-c-c# cached-compile
         my-e-f# execute-format
         my-i-n# init-navigator
         cf# (if (string? format-in#) (my-c-c# format-in#) format-in#)]
     (fn [stream# & args#]
       (let [navigator# (my-i-n# args#)]
         (my-e-f# stream# cf# navigator#)))))

(defmacro formatter-out
  "Makes a function which can directly run format-in. The function is
fn [& args] ... and returns nil. This version of the formatter macro is
designed to be used with *out* set to an appropriate Writer. In particular,
this is meant to be used as part of a pretty printer dispatch method.

format-in can be either a control string or a previously compiled format."
  {:added "1.2"}
  [format-in]
  `(let [format-in# ~format-in
         cf# (if (string? format-in#) (cached-compile format-in#) format-in#)]
     (fn [& args#]
       (let [navigator# (init-navigator args#)]
         (execute-format cf# navigator#)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; code-dispatch — pretty print dispatch for Clojure code
;;; UPSTREAM-DIFF: CW port of dispatch.clj (code-dispatch portions)
;;; Adaptations: predicate-based dispatch instead of multimethod on class,
;;;   cw-write instead of .write ^java.io.Writer, no Java array/IDeref support
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(declare pprint-simple-code-list)

;;; code-dispatch helper: format binding forms like let, loop, etc.
(defn- pprint-binding-form [binding-vec]
  (pprint-logical-block :prefix "[" :suffix "]"
                        (print-length-loop [binding binding-vec]
                                           (when (seq binding)
                                             (pprint-logical-block binding
                                                                   (write-out (first binding))
                                                                   (when (next binding)
                                                                     (cw-write " ")
                                                                     (pprint-newline :miser)
                                                                     (write-out (second binding))))
                                             (when (next (rest binding))
                                               (cw-write " ")
                                               (pprint-newline :linear)
                                               (recur (next (rest binding))))))))

;;; code-dispatch: hold-first form (def, defonce, ->, .., locking, struct, struct-map)
(defn- pprint-hold-first [alis]
  (pprint-logical-block :prefix "(" :suffix ")"
                        (pprint-indent :block 1)
                        (write-out (first alis))
                        (when (next alis)
                          (cw-write " ")
                          (pprint-newline :miser)
                          (write-out (second alis))
                          (when (next (rest alis))
                            (cw-write " ")
                            (pprint-newline :linear)
                            (print-length-loop [alis (next (rest alis))]
                                               (when alis
                                                 (write-out (first alis))
                                                 (when (next alis)
                                                   (cw-write " ")
                                                   (pprint-newline :linear)
                                                   (recur (next alis)))))))))

;;; code-dispatch: defn/defmacro/fn
(defn- single-defn [alis has-doc-str?]
  (when (seq alis)
    (if has-doc-str?
      ((formatter-out " ~_"))
      ((formatter-out " ~@_")))
    ((formatter-out "~{~w~^ ~_~}") alis)))

(defn- multi-defn [alis has-doc-str?]
  (when (seq alis)
    ((formatter-out " ~_~{~w~^ ~_~}") alis)))

(defn- pprint-defn [alis]
  (if (next alis)
    (let [[defn-sym defn-name & stuff] alis
          [doc-str stuff] (if (string? (first stuff))
                            [(first stuff) (next stuff)]
                            [nil stuff])
          [attr-map stuff] (if (map? (first stuff))
                             [(first stuff) (next stuff)]
                             [nil stuff])]
      (pprint-logical-block :prefix "(" :suffix ")"
                            ((formatter-out "~w ~1I~@_~w") defn-sym defn-name)
                            (when doc-str
                              ((formatter-out " ~_~w") doc-str))
                            (when attr-map
                              ((formatter-out " ~_~w") attr-map))
                            (cond
                              (vector? (first stuff)) (single-defn stuff (or doc-str attr-map))
                              :else (multi-defn stuff (or doc-str attr-map)))))
    (pprint-simple-code-list alis)))

;;; code-dispatch: let/loop/binding/with-open/when-let/if-let/doseq/dotimes
(defn- pprint-let [alis]
  (let [base-sym (first alis)]
    (pprint-logical-block :prefix "(" :suffix ")"
                          (if (and (next alis) (vector? (second alis)))
                            (do
                              ((formatter-out "~w ~1I~@_") base-sym)
                              (pprint-binding-form (second alis))
                              ((formatter-out " ~_~{~w~^ ~_~}") (next (rest alis))))
                            (pprint-simple-code-list alis)))))

;;; code-dispatch: if/if-not/when/when-not
(defn- pprint-if [alis]
  (pprint-logical-block :prefix "(" :suffix ")"
                        (pprint-indent :block 1)
                        (write-out (first alis))
                        (when (next alis)
                          (cw-write " ")
                          (pprint-newline :miser)
                          (write-out (second alis))
                          (doseq [clause (next (rest alis))]
                            (cw-write " ")
                            (pprint-newline :linear)
                            (write-out clause)))))

;;; code-dispatch: cond
(defn- pprint-cond [alis]
  (pprint-logical-block :prefix "(" :suffix ")"
                        (pprint-indent :block 1)
                        (write-out (first alis))
                        (when (next alis)
                          (cw-write " ")
                          (pprint-newline :linear)
                          (print-length-loop [alis (next alis)]
                                             (when alis
                                               (pprint-logical-block alis
                                                                     (write-out (first alis))
                                                                     (when (next alis)
                                                                       (cw-write " ")
                                                                       (pprint-newline :miser)
                                                                       (write-out (second alis))))
                                               (when (next (rest alis))
                                                 (cw-write " ")
                                                 (pprint-newline :linear)
                                                 (recur (next (rest alis)))))))))

;;; code-dispatch: condp
(defn- pprint-condp [alis]
  (if (> (count alis) 3)
    (pprint-logical-block :prefix "(" :suffix ")"
                          (pprint-indent :block 1)
                          (apply (formatter-out "~w ~@_~w ~@_~w ~_") alis)
                          (print-length-loop [alis (seq (drop 3 alis))]
                                             (when alis
                                               (pprint-logical-block alis
                                                                     (write-out (first alis))
                                                                     (when (next alis)
                                                                       (cw-write " ")
                                                                       (pprint-newline :miser)
                                                                       (write-out (second alis))))
                                               (when (next (rest alis))
                                                 (cw-write " ")
                                                 (pprint-newline :linear)
                                                 (recur (next (rest alis)))))))
    (pprint-simple-code-list alis)))

;;; code-dispatch: #() anonymous functions
(def ^:dynamic ^{:private true} *symbol-map* {})

(defn- pprint-anon-func [alis]
  (let [args (second alis)
        nlis (first (rest (rest alis)))]
    (if (vector? args)
      (binding [*symbol-map* (if (= 1 (count args))
                               {(first args) "%"}
                               (into {}
                                     (map
                                      #(vector %1 (str \% %2))
                                      args
                                      (range 1 (inc (count args))))))]
        ((formatter-out "~<#(~;~@{~w~^ ~_~}~;)~:>") nlis))
      (pprint-simple-code-list alis))))

;;; code-dispatch: ns macro
(defn- brackets [form]
  (if (vector? form) ["[" "]"] ["(" ")"]))

(defn- pprint-ns-reference [reference]
  (if (sequential? reference)
    (let [[start end] (brackets reference)
          [keyw & args] reference]
      (pprint-logical-block :prefix start :suffix end
                            ((formatter-out "~w~:i") keyw)
                            (loop [args args]
                              (when (seq args)
                                ((formatter-out " "))
                                (let [arg (first args)]
                                  (if (sequential? arg)
                                    (let [[start end] (brackets arg)]
                                      (pprint-logical-block :prefix start :suffix end
                                                            (if (and (= (count arg) 3) (keyword? (second arg)))
                                                              (let [[ns kw lis] arg]
                                                                ((formatter-out "~w ~w ") ns kw)
                                                                (if (sequential? lis)
                                                                  ((formatter-out (if (vector? lis)
                                                                                    "~<[~;~@{~w~^ ~:_~}~;]~:>"
                                                                                    "~<(~;~@{~w~^ ~:_~}~;)~:>"))
                                                                   lis)
                                                                  (write-out lis)))
                                                              (apply (formatter-out "~w ~:i~@{~w~^ ~:_~}") arg)))
                                      (when (next args) ((formatter-out "~_"))))
                                    (do
                                      (write-out arg)
                                      (when (next args) ((formatter-out "~:_"))))))
                                (recur (next args))))))
    (when reference (write-out reference))))

(defn- pprint-ns [alis]
  (if (next alis)
    (let [[ns-sym ns-name & stuff] alis
          [doc-str stuff] (if (string? (first stuff))
                            [(first stuff) (next stuff)]
                            [nil stuff])
          [attr-map references] (if (map? (first stuff))
                                  [(first stuff) (next stuff)]
                                  [nil stuff])]
      (pprint-logical-block :prefix "(" :suffix ")"
                            ((formatter-out "~w ~1I~@_~w") ns-sym ns-name)
                            (when (or doc-str attr-map (seq references))
                              ((formatter-out "~@:_")))
                            (when doc-str
                              (cl-format true "\"~a\"~:[~;~:@_~]" doc-str (or attr-map (seq references))))
                            (when attr-map
                              ((formatter-out "~w~:[~;~:@_~]") attr-map (seq references)))
                            (loop [references references]
                              (pprint-ns-reference (first references))
                              (when-let [references (next references)]
                                (pprint-newline :linear)
                                (recur references)))))
    (write-out alis)))

;;; Master code-dispatch list
(defn- pprint-simple-code-list [alis]
  (pprint-logical-block :prefix "(" :suffix ")"
                        (pprint-indent :block 1)
                        (print-length-loop [alis (seq alis)]
                                           (when alis
                                             (write-out (first alis))
                                             (when (next alis)
                                               (cw-write " ")
                                               (pprint-newline :linear)
                                               (recur (next alis)))))))

(defn- two-forms [amap]
  (into {}
        (mapcat
         identity
         (for [x amap]
           [x [(symbol (name (first x))) (second x)]]))))

(defn- add-core-ns [amap]
  (let [core "clojure.core"]
    (into {}
          (map #(let [[s f] %]
                  (if (not (or (namespace s) (special-symbol? s)))
                    [(symbol core (name s)) f]
                    %))
               amap))))

(def ^:dynamic ^{:private true} *code-table*
  (two-forms
   (add-core-ns
    {'def pprint-hold-first, 'defonce pprint-hold-first,
     'defn pprint-defn, 'defn- pprint-defn, 'defmacro pprint-defn, 'fn pprint-defn,
     'let pprint-let, 'loop pprint-let, 'binding pprint-let,
     'with-local-vars pprint-let, 'with-open pprint-let, 'when-let pprint-let,
     'if-let pprint-let, 'doseq pprint-let, 'dotimes pprint-let,
     'when-first pprint-let,
     'if pprint-if, 'if-not pprint-if, 'when pprint-if, 'when-not pprint-if,
     'cond pprint-cond, 'condp pprint-condp,
     'fn* pprint-anon-func,
     '. pprint-hold-first, '.. pprint-hold-first, '-> pprint-hold-first,
     'locking pprint-hold-first, 'struct pprint-hold-first,
     'struct-map pprint-hold-first, 'ns pprint-ns})))

(defn- pprint-code-list [alis]
  (if-not (let [reader-macros {'quote "'" 'clojure.core/deref "@"
                               'var "#'" 'clojure.core/unquote "~"}
                macro-char (reader-macros (first alis))]
            (when (and macro-char (= 2 (count alis)))
              (cw-write macro-char)
              (write-out (second alis))
              true))
    (if-let [special-form (get *code-table* (first alis))]
      (special-form alis)
      (pprint-simple-code-list alis))))

(defn- pprint-code-symbol [sym]
  (if-let [arg-num (get *symbol-map* sym)]
    (cw-write (str arg-num))
    (if *print-suppress-namespaces*
      (cw-write (name sym))
      (cw-write (pr-str sym)))))

(defn code-dispatch
  "The pretty print dispatch function for pretty printing Clojure code."
  {:added "1.2"}
  [object]
  (cond
    (nil? object) (cw-write (pr-str nil))
    (seq? object) (pprint-code-list object)
    (symbol? object) (pprint-code-symbol object)
    (vector? object) (pprint-vector object)
    (map? object) (pprint-map object)
    (set? object) (pprint-set object)
    :else (pprint-simple-default object)))

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
