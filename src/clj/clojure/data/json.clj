;; Copyright (c) Stuart Sierra, 2012. All rights reserved.  The use
;; and distribution terms for this software are covered by the Eclipse
;; Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;; which can be found in the file epl-v10.html at the root of this
;; distribution.  By using this software in any fashion, you are
;; agreeing to be bound by the terms of this license.  You must not
;; remove this notice, or any other, from this software.

;; CLJW: CW-compatible fork of clojure.data.json
;; Upstream: clojure/data.json (Stuart Sierra)
;; UPSTREAM-DIFF: Replaced Java I/O (definterface, deftype, StringWriter,
;; PushbackReader, char-array, short-array) with pure Clojure equivalents.
;; Reader-based `read` function not available — use `read-str` instead.
;; Date/Instant/SqlDate writers not available — CW has no java.time.

(ns ^{:author "Stuart Sierra, CW fork"
      :doc "JavaScript Object Notation (JSON) parser/generator.
  See http://www.json.org/
  CW fork: string-based only (read-str/write-str)."}
 clojure.data.json
  (:refer-clojure :exclude (read)))

;;; String-based pushback reader using volatile + reify

(defprotocol InternalPBR
  (-read-char [this])
  (-unread-char [this c]))

(defn- string-pbr
  [^String s]
  (let [pos (volatile! 0)
        len (count s)]
    (reify InternalPBR
      (-read-char [_]
        (let [p @pos]
          (if (< p len)
            (do (vswap! pos inc)
                (int (.charAt s p)))
            -1)))
      (-unread-char [_ c]
        (vswap! pos dec)
        nil))))

;;; String-based output builder using volatile

(defprotocol IAppendable
  (-append-char [this c])
  (-append-str [this s])
  (-append-sub [this s start end])
  (-to-string [this]))

(defn- make-appendable []
  (let [parts (volatile! [])]
    (reify IAppendable
      (-append-char [this c]
        (vswap! parts conj (str c))
        this)
      (-append-str [this s]
        (vswap! parts conj s)
        this)
      (-append-sub [this s start end]
        (vswap! parts conj (subs s start end))
        this)
      (-to-string [_]
        (apply str @parts)))))

;;; JSON READER

(defn- default-write-key-fn
  [x]
  (cond (or (keyword? x) (symbol? x))
        (name x)
        (nil? x)
        (throw (ex-info "JSON object properties may not be nil" {}))
        :else (str x)))

(defn- default-value-fn [k v] v)

(declare -read)

;; CLJW: pure Clojure hex digit parser (Integer/parseInt with radix not supported)
(defn- hex-digit [c]
  (cond
    (and (>= c 48) (<= c 57))  (- c 48)       ;; 0-9
    (and (>= c 65) (<= c 70))  (- c 55)       ;; A-F
    (and (>= c 97) (<= c 102)) (- c 87)       ;; a-f
    :else (throw (ex-info (str "JSON error (invalid hex digit): " (char c)) {}))))

(defn- read-hex-char [stream]
  (let [a (-read-char stream)
        b (-read-char stream)
        c (-read-char stream)
        d (-read-char stream)]
    (when (or (neg? a) (neg? b) (neg? c) (neg? d))
      (throw (ex-info "JSON error (end-of-file inside Unicode character escape)" {})))
    (char (+ (* (hex-digit a) 4096)
             (* (hex-digit b) 256)
             (* (hex-digit c) 16)
             (hex-digit d)))))

(defn- read-escaped-char [stream]
  (let [c (-read-char stream)]
    (when (neg? c)
      (throw (ex-info "JSON error (end-of-file inside escaped char)" {})))
    (case c
      (34 92 47) (char c)  ;; \" \\ \/
      98 \backspace         ;; \b
      102 \formfeed         ;; \f
      110 \newline          ;; \n
      114 \return           ;; \r
      116 \tab              ;; \t
      117 (read-hex-char stream)  ;; \u
      (throw (ex-info (str "JSON error (invalid escaped char): " (char c)) {})))))

(defn- read-quoted-string [stream]
  (let [buf (volatile! [])]
    (loop []
      (let [c (-read-char stream)]
        (when (neg? c)
          (throw (ex-info "JSON error (end-of-file inside string)" {})))
        (case c
          34 (apply str @buf)  ;; \"
          92 (do (vswap! buf conj (read-escaped-char stream))  ;; \\
                 (recur))
          (do (vswap! buf conj (char c))
              (recur)))))))

(defn- read-integer [string]
  (if (< (count string) 18)
    (Long/valueOf string)
    (or (try (Long/valueOf string) (catch Exception e nil))
        (bigint string))))

(defn- read-decimal [string bigdec?]
  (if bigdec?
    (bigdec string)
    (Double/valueOf string)))

(defn- digit? [c]
  (and (>= c 48) (<= c 57)))

(defn- read-number [stream bigdec?]
  (let [buf (volatile! [])
        append! (fn [c] (vswap! buf conj (char c)))
        decimal?
        (loop [stage :minus]
          (let [c (-read-char stream)]
            ;; CLJW: use condp instead of case (CW case hash collision with 8+ kw branches)
            (condp = stage
              :minus
              (cond
                (= c 45) (do (append! c) (recur :int-zero))   ;; -
                (= c 48) (do (append! c) (recur :frac-point)) ;; 0
                (and (>= c 49) (<= c 57)) (do (append! c) (recur :int-digit))
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :int-zero
              (cond
                (= c 48) (do (append! c) (recur :frac-point))
                (and (>= c 49) (<= c 57)) (do (append! c) (recur :int-digit))
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :int-digit
              (cond
                (digit? c) (do (append! c) (recur :int-digit))
                (= c 46) (do (append! c) (recur :frac-first))   ;; .
                (or (= c 101) (= c 69)) (do (append! c) (recur :exp-symbol)) ;; e E
                (or (= c 9) (= c 10) (= c 13) (= c 32)) (do (-unread-char stream c) false)
                (or (= c 44) (= c 93) (= c 125)) (do (-unread-char stream c) false) ;; , ] }
                (= c -1) false
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :frac-point
              (cond
                (= c 46) (do (append! c) (recur :frac-first))
                (or (= c 101) (= c 69)) (do (append! c) (recur :exp-symbol))
                (or (= c 9) (= c 10) (= c 13) (= c 32)) (do (-unread-char stream c) false)
                (or (= c 44) (= c 93) (= c 125)) (do (-unread-char stream c) false)
                (= c -1) false
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :frac-first
              (cond
                (digit? c) (do (append! c) (recur :frac-digit))
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :frac-digit
              (cond
                (digit? c) (do (append! c) (recur :frac-digit))
                (or (= c 101) (= c 69)) (do (append! c) (recur :exp-symbol))
                (or (= c 9) (= c 10) (= c 13) (= c 32)) (do (-unread-char stream c) true)
                (or (= c 44) (= c 93) (= c 125)) (do (-unread-char stream c) true)
                (= c -1) true
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :exp-symbol
              (cond
                (or (= c 45) (= c 43)) (do (append! c) (recur :exp-first))
                (digit? c) (do (append! c) (recur :exp-digit))
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :exp-first
              (cond
                (digit? c) (do (append! c) (recur :exp-digit))
                :else (throw (ex-info "JSON error (invalid number literal)" {})))
              :exp-digit
              (cond
                (digit? c) (do (append! c) (recur :exp-digit))
                (or (= c 9) (= c 10) (= c 13) (= c 32)) (do (-unread-char stream c) true)
                (or (= c 44) (= c 93) (= c 125)) (do (-unread-char stream c) true)
                (= c -1) true
                :else (throw (ex-info "JSON error (invalid number literal)" {}))))))]
    (let [s (apply str @buf)]
      (if decimal?
        (read-decimal s bigdec?)
        (read-integer s)))))

(defn- next-token [stream]
  (loop [c (-read-char stream)]
    (if (> c 32)
      c
      (if (or (= c 9) (= c 10) (= c 13) (= c 32))
        (recur (-read-char stream))
        c))))

(defn- read-array [stream options]
  (let [c (next-token stream)]
    (cond
      (= c 93) []  ;; ]
      (= c 44) (throw (ex-info "JSON error (invalid array)" {}))  ;; ,
      (= c -1) (throw (ex-info "JSON error (EOF in array)" {}))
      :else
      (do (-unread-char stream c)
          (loop [result (transient [])]
            (let [r (conj! result (-read stream true nil options))
                  t (next-token stream)]
              (cond
                (= t 93) (persistent! r)   ;; ]
                (= t 44) (recur r)          ;; ,
                (= t -1) (throw (ex-info "JSON error (EOF in array)" {}))
                :else (throw (ex-info "JSON error (invalid array)" {})))))))))

(defn- read-key [stream]
  (let [c (next-token stream)]
    (cond
      (= c 34)  ;; "
      (let [key (read-quoted-string stream)]
        (if (= 58 (next-token stream))  ;; :
          key
          (throw (ex-info "JSON error (missing `:` in object)" {}))))
      (= c 125) nil  ;; }
      (= c -1) (throw (ex-info "JSON error (EOF in object)" {}))
      :else (throw (ex-info (str "JSON error (non-string key in object), found `"
                                 (char c) "`, expected `\"`") {})))))

(defn- read-object [stream options]
  (let [key-fn (get options :key-fn)
        value-fn (get options :value-fn)]
    (loop [result (transient {})]
      (if-let [key (read-key stream)]
        (let [key (cond-> key key-fn key-fn)
              value (-read stream true nil options)
              r (if value-fn
                  (let [out-value (value-fn key value)]
                    (if-not (= value-fn out-value)
                      (assoc! result key out-value)
                      result))
                  (assoc! result key value))]
          (let [t (next-token stream)]
            (cond
              (= t 44) (recur r)   ;; ,
              (= t 125) (persistent! r)  ;; }
              (= t -1) (throw (ex-info "JSON error (EOF in object)" {}))
              :else (throw (ex-info "JSON error (missing entry in object)" {})))))
        (let [r (persistent! result)]
          (if (empty? r)
            r
            (throw (ex-info "JSON error empty entry in object is not allowed" {}))))))))

(defn- -read
  [stream eof-error? eof-value options]
  (let [c (next-token stream)]
    (cond
      ;; Read numbers
      (or (= c 45) (digit? c))  ;; - or 0-9
      (do (-unread-char stream c)
          (read-number stream (:bigdec options)))

      ;; Read strings
      (= c 34)  ;; "
      (read-quoted-string stream)

      ;; Read null as nil
      (= c 110)  ;; n
      (if (and (= 117 (-read-char stream))   ;; u
               (= 108 (-read-char stream))   ;; l
               (= 108 (-read-char stream)))  ;; l
        nil
        (throw (ex-info "JSON error (expected null)" {})))

      ;; Read true
      (= c 116)  ;; t
      (if (and (= 114 (-read-char stream))   ;; r
               (= 117 (-read-char stream))   ;; u
               (= 101 (-read-char stream)))  ;; e
        true
        (throw (ex-info "JSON error (expected true)" {})))

      ;; Read false
      (= c 102)  ;; f
      (if (and (= 97 (-read-char stream))    ;; a
               (= 108 (-read-char stream))   ;; l
               (= 115 (-read-char stream))   ;; s
               (= 101 (-read-char stream)))  ;; e
        false
        (throw (ex-info "JSON error (expected false)" {})))

      ;; Read JSON objects
      (= c 123)  ;; {
      (read-object stream options)

      ;; Read JSON arrays
      (= c 91)  ;; [
      (read-array stream options)

      ;; Handle end-of-stream
      (neg? c)
      (if eof-error?
        (throw (ex-info "JSON error (end-of-file)" {}))
        eof-value)

      :else
      (throw (ex-info (str "JSON error (unexpected character): " (char c)) {})))))

(def default-read-options {:bigdec false
                           :key-fn nil
                           :value-fn nil})

(defn read-str
  "Reads one JSON value from input String. Options are key-value pairs:

     :eof-error? boolean (default true)
     :eof-value Object (default nil)
     :bigdec boolean (default false)
     :key-fn function
     :value-fn function"
  [string & {:as options}]
  (let [{:keys [eof-error? eof-value]
         :or {eof-error? true}} options]
    (->> options
         (merge default-read-options)
         (-read (string-pbr string) eof-error? eof-value))))

;;; JSON WRITER

(defprotocol JSONWriter
  (-write [object out options]
    "Print object to out as JSON"))

(defn- ->hex-string [out cp]
  (let [cpl (long cp)]
    (-append-str out "\\u")
    (cond
      (< cpl 16)   (-append-str out "000")
      (< cpl 256)  (-append-str out "00")
      (< cpl 4096) (-append-str out "0"))
    (-append-str out (Integer/toHexString cp))))

(defn- escape-char? [cp]
  (cond
    (= cp 34) :quote       ;; \"
    (= cp 92) :backslash   ;; \\
    (= cp 47) :slash       ;; /
    (= cp 8)  :backspace
    (= cp 12) :formfeed
    (= cp 10) :newline
    (= cp 13) :return
    (= cp 9)  :tab
    (< cp 32) :control
    :else nil))

(defn- write-string-char [out cp options]
  (let [esc (escape-char? cp)]
    (case esc
      :quote     (do (-append-str out "\\\"") nil)
      :backslash (do (-append-str out "\\\\") nil)
      :slash     (if (get options :escape-slash)
                   (-append-str out "\\/")
                   (-append-char out \/))
      :backspace (-append-str out "\\b")
      :formfeed  (-append-str out "\\f")
      :newline   (-append-str out "\\n")
      :return    (-append-str out "\\r")
      :tab       (-append-str out "\\t")
      :control   (->hex-string out cp)
      (cond
        ;; JS separators U+2028, U+2029
        (or (= cp 0x2028) (= cp 0x2029))
        (if (get options :escape-js-separators)
          (->hex-string out cp)
          (-append-char out (char cp)))
        ;; Non-ASCII
        (> cp 127)
        (if (get options :escape-unicode)
          (->hex-string out cp)
          (-append-char out (char cp)))
        :else
        (-append-char out (char cp))))))

(defn- write-string [s out options]
  (-append-char out \")
  ;; CLJW: iterate by Unicode codepoints via seq (not bytes via .charAt)
  (doseq [c s]
    (write-string-char out (int c) options))
  (-append-char out \"))

(defn- write-indent [out options]
  (let [indent-depth (:indent-depth options)]
    (-append-char out \newline)
    (dotimes [_ indent-depth]
      (-append-str out "  "))))

(defn- write-object [m out options]
  (let [key-fn (get options :key-fn)
        value-fn (get options :value-fn)
        indent (get options :indent)
        opts (cond-> options
               indent (update :indent-depth inc))]
    (-append-char out \{)
    (when (and indent (seq m))
      (write-indent out opts))
    (loop [x (seq m), have-printed-kv false]
      (when x
        (let [[k v] (first x)
              out-key (key-fn k)
              out-value (value-fn k v)
              nxt (next x)]
          (when-not (string? out-key)
            (throw (ex-info "JSON object keys must be strings" {})))
          (if-not (= value-fn out-value)
            (do
              (when have-printed-kv
                (-append-char out \,)
                (when indent
                  (write-indent out opts)))
              (write-string out-key out opts)
              (-append-char out \:)
              (when indent
                (-append-char out \space))
              (-write out-value out opts)
              (when nxt
                (recur nxt true)))
            (when nxt
              (recur nxt have-printed-kv))))))
    (when (and indent (seq m))
      (write-indent out options)))
  (-append-char out \}))

(defn- write-array [s out options]
  (let [indent (get options :indent)
        opts (cond-> options
               indent (update :indent-depth inc))]
    (-append-char out \[)
    (when (and indent (seq s))
      (write-indent out opts))
    (loop [x (seq s)]
      (when x
        (let [fst (first x)
              nxt (next x)]
          (-write fst out opts)
          (when nxt
            (-append-char out \,)
            (when indent
              (write-indent out opts))
            (recur nxt)))))
    (when (and indent (seq s))
      (write-indent out options)))
  (-append-char out \]))

(defn- write-named [x out options]
  (write-string (name x) out options))

;; CLJW: extend-protocol to CW types
(extend-protocol JSONWriter
  nil
  (-write [_ out _]
    (-append-str out "null"))

  Boolean
  (-write [b out _]
    (-append-str out (str b)))

  Long
  (-write [n out _]
    (-append-str out (str n)))

  Double
  (-write [x out _]
    (cond (Double/isInfinite x)
          (throw (ex-info "JSON error: cannot write infinite Double" {}))
          (Double/isNaN x)
          (throw (ex-info "JSON error: cannot write Double NaN" {}))
          :else
          (-append-str out (str x))))

  String
  (-write [s out options]
    (write-string s out options))

  Keyword
  (-write [k out options]
    (write-named k out options))

  Symbol
  (-write [s out options]
    (write-named s out options))

  ;; CLJW: Object as catch-all for maps, collections, ratios, bigints, etc.
  Object
  (-write [x out options]
    (cond
      ;; CLJW: uuid? before map? (CW UUIDs have map? = true)
      (uuid? x)       (do (-append-char out \")
                          (-append-str out (str x))
                          (-append-char out \"))
      (map? x)        (write-object x out options)
      (or (vector? x)
          (list? x)
          (set? x)
          (seq? x))   (write-array x out options)
      (ratio? x)      (-write (double x) out options)
      (integer? x)    (-append-str out (str x))  ;; BigInt etc
      (decimal? x)    (-append-str out (str x))  ;; BigDecimal
      :else
      (let [f (:default-write-fn options)]
        (if f
          (f x out options)
          (throw (ex-info (str "Don't know how to write JSON of " (type x)) {})))))))

(defn- default-write-fn [x out options]
  (throw (ex-info (str "Don't know how to write JSON of " (type x)) {})))

(def default-write-options {:escape-unicode true
                            :escape-js-separators true
                            :escape-slash true
                            :key-fn default-write-key-fn
                            :value-fn default-value-fn
                            :default-write-fn default-write-fn
                            :indent false
                            :indent-depth 0})

(defn write-str
  "Converts x to a JSON-formatted string. Options are key-value pairs:

    :escape-unicode boolean (default true)
    :escape-js-separators boolean (default true)
    :escape-slash boolean (default true)
    :key-fn function
    :value-fn function
    :default-write-fn function
    :indent boolean (default false)"
  ^String [x & {:as options}]
  (let [out (make-appendable)]
    (-write x out (merge default-write-options options))
    (-to-string out)))

;;; Deprecated APIs from 0.1.x

(defn read-json
  "DEPRECATED; replaced by read-str."
  ([input]
   (read-json input true true nil))
  ([input keywordize?]
   (read-json input keywordize? true nil))
  ([input keywordize? eof-error? eof-value]
   (let [key-fn (if keywordize? keyword identity)]
     (read-str input
               :key-fn key-fn
               :eof-error? eof-error?
               :eof-value eof-value))))

(defn json-str
  "DEPRECATED; replaced by 'write-str'."
  [x & options]
  (apply write-str x options))
