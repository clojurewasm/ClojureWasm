;; scripts/dev/bencode.cljc — bencode for the nREPL dev loop.
;;
;; PORTABLE BY CONSTRUCTION: no reader conditionals in this file. It uses only
;; the portable core surface, so the same bytes-on-the-wire logic runs under
;; cljw AND under babashka. That is the point — the dev tooling is one language
;; across both runtimes, and running it under cljw dogfoods cljw's byte-array,
;; string and UTF-8 handling every time the loop is used.
;;
;; Decoders take a vector of unsigned byte values and return [value next-index],
;; or nil when the buffer holds only part of a value — that nil is what lets a
;; reader wait for more bytes instead of failing on a partial read.
;;
;; Shape modelled on hive bb-mcp's bb-mcp.wire.bencode (verified to load and
;; round-trip under cljw before this was written); independent implementation.
(ns dev.bencode)

;; --- encode ---------------------------------------------------------------
;; The length prefix is a BYTE count, not a character count. Getting this wrong
;; desyncs the stream on any non-ASCII payload (e.g. "日本語" is 9 bytes, 3 chars).
(defn bstr [s]
  (let [s (str s)]
    (str (alength (.getBytes s "UTF-8")) ":" s)))

(defn encode-dict
  "Bencode a map of string->string. Keys are emitted in sorted order, as the
   spec requires."
  [m]
  (str "d"
       (apply str (map (fn [k] (str (bstr k) (bstr (get m k)))) (sort (keys m))))
       "e"))

;; --- decode ---------------------------------------------------------------
(declare decode-at)

(defn- digits-until [buf i stop]
  (loop [j i acc ""]
    (cond
      (>= j (count buf)) nil
      (= (nth buf j) stop) [acc (inc j)]
      :else (recur (inc j) (str acc (char (nth buf j)))))))

(defn- decode-string [buf i]
  (let [r (digits-until buf i 58)]                 ; 58 = \:
    (when r
      (let [n (Integer/parseInt (first r))
            j (second r)
            end (+ j n)]
        (when (<= end (count buf))
          [(String. (byte-array (subvec buf j end)) "UTF-8") end])))))

(defn- decode-int [buf i]
  (let [r (digits-until buf (inc i) 101)]          ; 101 = \e
    (when r [(Long/parseLong (first r)) (second r)])))

(defn- decode-list [buf i]
  (loop [j (inc i) acc []]
    (cond
      (>= j (count buf)) nil
      (= (nth buf j) 101) [acc (inc j)]
      :else (let [r (decode-at buf j)]
              (when r (recur (second r) (conj acc (first r))))))))

(defn- decode-dict [buf i]
  (loop [j (inc i) acc {}]
    (cond
      (>= j (count buf)) nil
      (= (nth buf j) 101) [acc (inc j)]
      :else
      (let [k (decode-at buf j)]
        (when k
          (let [v (decode-at buf (second k))]
            (when v
              (recur (second v) (assoc acc (first k) (first v))))))))))

(defn decode-at
  "Decode one value from `buf` at index `i`. => [value next-index] | nil."
  [buf i]
  (when (< i (count buf))
    (let [c (nth buf i)]
      (cond
        (= c 100) (decode-dict buf i)              ; \d
        (= c 108) (decode-list buf i)              ; \l
        (= c 105) (decode-int buf i)               ; \i
        :else     (decode-string buf i)))))

(defn decode-all
  "Every COMPLETE value in `buf` from `start`. => [values next-index]. The
   next-index lets a caller keep ONE growing buffer and resume where the last
   pass stopped instead of re-decoding from zero."
  [buf start]
  (loop [i start acc []]
    (let [r (decode-at buf i)]
      (if r
        (recur (second r) (conj acc (first r)))
        [acc i]))))
