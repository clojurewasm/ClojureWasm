;; Copyright (c) Jonas Enlund. All rights reserved.  The use and
;; distribution terms for this software are covered by the Eclipse
;; Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;; which can be found in the file epl-v10.html at the root of this
;; distribution.  By using this software in any fashion, you are
;; agreeing to be bound by the terms of this license.  You must not
;; remove this notice, or any other, from this software.

;; CLJW: CW-compatible fork of clojure.data.csv
;; Upstream: clojure/data.csv (Jonas Enlund)
;; UPSTREAM-DIFF: Replaced Java I/O (PushbackReader, Writer, StringBuilder,
;; StringReader) with string-based + volatile! equivalents.
;; read-csv reads from String only. write-csv returns a String.

(ns ^{:author "Jonas Enlund, CW fork"
      :doc "Reading and writing comma separated values.
  CW fork: string-based only (no java.io.Reader/Writer)."}
 clojure.data.csv
  (:require [clojure.string :as str]))

;; CLJW: String-based pushback reader (same approach as data.json)
(defprotocol IPBR
  (-read [this])
  (-unread [this c]))

(defn- string-pbr [^String s]
  (let [pos (volatile! 0)
        len (count s)]
    (reify IPBR
      (-read [_]
        (let [p @pos]
          (if (< p len)
            (do (vswap! pos inc)
                (int (.charAt s p)))
            -1)))
      (-unread [_ c]
        (vswap! pos dec)
        nil))))

;; Reading

(def ^{:private true} lf  (int \newline))
(def ^{:private true} cr  (int \return))
(def ^{:private true} eof -1)

(defn- read-quoted-cell [reader sb sep quote]
  (loop [ch (-read reader)]
    (condp == ch
      quote (let [next-ch (-read reader)]
              (condp == next-ch
                quote (do (vswap! sb conj (char quote))
                          (recur (-read reader)))
                sep :sep
                lf  :eol
                cr  (let [next-next-ch (-read reader)]
                      (when (not= next-next-ch lf)
                        (-unread reader next-next-ch))
                      :eol)
                eof :eof
                (throw (ex-info (str "CSV error (unexpected character: " (char next-ch) ")") {}))))
      eof (throw (ex-info "CSV error (unexpected end of file)" {}))
      (do (vswap! sb conj (char ch))
          (recur (-read reader))))))

(defn- read-cell [reader sb sep quote]
  (let [first-ch (-read reader)]
    (if (== first-ch quote)
      (read-quoted-cell reader sb sep quote)
      (loop [ch first-ch]
        (condp == ch
          sep :sep
          lf  :eol
          cr (let [next-ch (-read reader)]
               (when (not= next-ch lf)
                 (-unread reader next-ch))
               :eol)
          eof :eof
          (do (vswap! sb conj (char ch))
              (recur (-read reader))))))))

(defn- read-record [reader sep quote]
  (loop [record (transient [])]
    (let [cell (volatile! [])
          sentinel (read-cell reader cell sep quote)]
      (if (= sentinel :sep)
        (recur (conj! record (apply str @cell)))
        [(persistent! (conj! record (apply str @cell))) sentinel]))))

(defn- read-csv-from [reader sep quote]
  (lazy-seq
   (let [[record sentinel] (read-record reader sep quote)]
     (case sentinel
       :eol (cons record (read-csv-from reader sep quote))
       :eof (when-not (= record [""])
              (cons record nil))))))

(defn read-csv
  "Reads CSV-data from input String into a lazy sequence of vectors.

   Valid options are
     :separator (default \\,)
     :quote (default \\\")"
  [input & options]
  (let [{:keys [separator quote] :or {separator \, quote \"}} options]
    (read-csv-from (string-pbr input) (int separator) (int quote))))

;; Writing

;; CLJW: write path keeps sep/quote as chars (not ints).
;; CW's (char int) returns a string, not a char, so map lookup in
;; str/escape fails. Upstream also passes chars here (int only for read path).
(defn- write-cell [out obj sep quote quote?]
  (let [string (str obj)
        must-quote (quote? string)]
    (when must-quote (vswap! out conj (str quote)))
    (vswap! out conj (if must-quote
                       (str/escape string {quote (str quote quote)})
                       string))
    (when must-quote (vswap! out conj (str quote)))))

(defn- write-record [out record sep quote quote?]
  (loop [record record]
    (when-first [cell record]
      (write-cell out cell sep quote quote?)
      (when-let [more (next record)]
        (vswap! out conj (str sep))
        (recur more)))))

(defn- write-csv* [out records sep quote quote? newline]
  (loop [records records]
    (when-first [record records]
      (write-record out record sep quote quote?)
      (vswap! out conj newline)
      (recur (next records)))))

(defn write-csv
  "Writes data to a string in CSV-format.
   Returns the CSV string.

   Valid options are
     :separator (Default \\,)
     :quote (Default \\\")
     :quote? (A predicate function which determines if a string should be quoted.
              Defaults to quoting only when necessary.)
     :newline (:lf (default) or :cr+lf)"
  [data & options]
  (let [opts (apply hash-map options)
        separator (or (:separator opts) \,)
        quote (or (:quote opts) \")
        quote? (or (:quote? opts)
                   (let [should-quote #{separator quote \return \newline}]
                     #(some should-quote %)))
        newline (or (:newline opts) :lf)
        out (volatile! [])]
    (write-csv* out data separator quote quote?
                ({:lf "\n" :cr+lf "\r\n"} newline))
    (apply str @out)))
