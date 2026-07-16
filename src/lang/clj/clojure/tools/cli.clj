;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.tools.cli API (originally Clojure contrib (tools.cli); Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.tools.cli — argument parser. cw v1 §9.11 row 9.5.
;;
;; Pure-Clojure `parse-opts` (the §9.11 Zig MVP was the skeleton; this is
;; its finished-form rewrite — option parsing is Clojure-expressible
;; logic). Surface per JVM tools.cli 1.1: 2/3-positional specs + kv
;; options (:id :default :default-desc :default-fn :parse-fn :update-fn
;; :assoc-fn :validate :missing), `--opt=val`, `--[no-]opt`, grouped
;; boolean shorts (-vvv), the `--` terminator, and the parse-opts kwargs
;; :in-order / :no-defaults.
(ns clojure.tools.cli
  (:refer-clojure)
  (:require [clojure.string :as s]))

(def ^:private compile-spec
  (fn [spec]
    (let [[positional kvs] (split-with (complement keyword?) spec)
          [short-opt long-opt desc] positional
          m (apply hash-map kvs)
          short-opt (when (and short-opt (seq short-opt)) short-opt)
          no-prefix? (boolean (and long-opt (s/starts-with? long-opt "--[no-]")))
          ;; "--port PORT" → flag "--port", required-arg label "PORT";
          ;; "--[no-]daemon" → flag "--daemon" (also matches "--no-daemon").
          long-body (when long-opt
                      (if no-prefix? (str "--" (subs long-opt 7)) long-opt))
          sp-idx (when long-body (s/index-of long-body " "))
          long-flag (when long-body (if sp-idx (subs long-body 0 sp-idx) long-body))
          required (when (and long-body sp-idx) (subs long-body (inc sp-idx)))
          id (or (:id m) (when long-flag (keyword (subs long-flag 2))))]
      (merge {:id id
              :short-opt short-opt
              :long-opt long-flag
              :required required
              :no-prefix? no-prefix?
              :desc (or desc "")}
             (dissoc m :id)))))

(def ^:private find-short
  (fn [specs t] (first (filter (fn [sp] (= t (:short-opt sp))) specs))))

(def ^:private find-long
  (fn [specs t]
    (or (first (filter (fn [sp] (= t (:long-opt sp))) specs))
        ;; "--no-daemon" matches a --[no-]daemon spec (negated form).
        (when (s/starts-with? t "--no-")
          (first (filter (fn [sp]
                           (and (:no-prefix? sp)
                                (= (:long-opt sp) (str "--" (subs t 5)))))
                         specs))))))

;; Apply one matched occurrence onto the options map. `raw` is the raw
;; string argument (nil for a flag); `negated?` marks a --no-X match.
;; Returns {:options m :errors v}.
(def ^:private apply-spec
  (fn [options errors spec optname raw negated?]
    (let [parse-fn (:parse-fn spec)
          label (if (some? raw) (str optname " " raw) optname)
          parsed (try
                   {:value (if (some? raw)
                             (if parse-fn (parse-fn raw) raw)
                             (not negated?))}
                   (catch Throwable e
                     {:error (str "Error while parsing option " (pr-str label)
                                  ": " (ex-message e))}))]
      (if (:error parsed)
        {:options options :errors (conj errors (:error parsed))}
        (let [value (:value parsed)
              pairs (partition 2 (or (:validate spec) []))
              bad (first (filter (fn [pair]
                                   (not (try ((first pair) value)
                                             (catch Throwable _ false))))
                                 pairs))]
          (if bad
            {:options options
             :errors (conj errors (str "Failed to validate " (pr-str label)
                                       (when (second bad) (str ": " (second bad)))))}
            {:options (cond
                        (:update-fn spec) (update options (:id spec) (:update-fn spec))
                        (:assoc-fn spec) ((:assoc-fn spec) options (:id spec) value)
                        :else (assoc options (:id spec) value))
             :errors errors}))))))

;; Summary: "  -p, --port PORT  Port" — a short column ("-p," padded),
;; the long flag (+ arg label), then (when any spec carries a default) a
;; default column, then the description; two-space gutters, trailing trim.
(def ^:private make-summary
  (fn [specs]
    (if (empty? specs)
      ""
      (let [show-defaults? (boolean (some (fn [sp] (or (contains? sp :default)
                                                       (contains? sp :default-fn)))
                                          specs))
            rows (mapv (fn [sp]
                         (let [short-col (if (:short-opt sp) (str (:short-opt sp) ",") "")
                               long-col (str (or (:long-opt sp) "")
                                             (when (:required sp) (str " " (:required sp))))
                               base [short-col long-col]
                               base (if show-defaults?
                                      (conj base (or (:default-desc sp)
                                                     (if (contains? sp :default)
                                                       (pr-str (:default sp))
                                                       "")))
                                      base)]
                           (conj base (or (:desc sp) ""))))
                       specs)
            ncols (count (first rows))
            widths (mapv (fn [i] (apply max (map (fn [r] (count (nth r i))) rows)))
                         (range ncols))
            pad (fn [c w] (str c (apply str (repeat (- w (count c)) " "))))]
        (s/join "\n"
          (map (fn [row]
                 (s/trimr
                   (str "  " (pad (nth row 0) (nth widths 0)) " "
                        (s/join "  " (map-indexed (fn [i c] (pad c (nth widths (inc i))))
                                                  (rest row))))))
               rows))))))

(def parse-opts
  (fn [args option-specs & {:keys [in-order no-defaults]}]
    (let [specs (mapv compile-spec option-specs)
          defaults (reduce (fn [m sp]
                             (if (contains? sp :default)
                               (assoc m (:id sp) (:default sp))
                               m))
                           {} specs)
          parsed
          (loop [tokens (seq args)
                 options (if no-defaults {} defaults)
                 arguments []
                 errors []]
            (if-not tokens
              {:options options :arguments arguments :errors errors}
              (let [t (first tokens)
                    more (next tokens)]
                (cond
                  (= t "--")
                  {:options options :arguments (into arguments more) :errors errors}

                  (and (s/starts-with? t "--") (s/includes? t "="))
                  (let [i (s/index-of t "=")
                        optname (subs t 0 i)
                        raw (subs t (inc i))
                        sp (find-long specs optname)]
                    (if sp
                      (let [r (apply-spec options errors sp optname raw false)]
                        (recur more (:options r) arguments (:errors r)))
                      (recur more options arguments
                             (conj errors (str "Unknown option: " (pr-str optname))))))

                  (s/starts-with? t "--")
                  (let [sp (find-long specs t)]
                    (cond
                      (nil? sp)
                      (recur more options arguments
                             (conj errors (str "Unknown option: " (pr-str t))))

                      (:required sp)
                      (if (and more (not (s/starts-with? (first more) "-")))
                        (let [r (apply-spec options errors sp t (first more) false)]
                          (recur (next more) (:options r) arguments (:errors r)))
                        (recur more options arguments
                               (conj errors (str "Missing required argument for "
                                                 (pr-str (str t " " (:required sp)))))))

                      :else
                      (let [negated? (and (:no-prefix? sp) (s/starts-with? t "--no-"))
                            r (apply-spec options errors sp t nil negated?)]
                        (recur more (:options r) arguments (:errors r)))))

                  (and (s/starts-with? t "-") (> (count t) 1))
                  (if (= 2 (count t))
                    (let [sp (find-short specs t)]
                      (cond
                        (nil? sp)
                        (recur more options arguments
                               (conj errors (str "Unknown option: " (pr-str t))))

                        (:required sp)
                        (if (and more (not (s/starts-with? (first more) "-")))
                          (let [r (apply-spec options errors sp t (first more) false)]
                            (recur (next more) (:options r) arguments (:errors r)))
                          (recur more options arguments
                                 (conj errors (str "Missing required argument for "
                                                   (pr-str (str t " " (:required sp)))))))

                        :else
                        (let [r (apply-spec options errors sp t nil false)]
                          (recur more (:options r) arguments (:errors r)))))
                    ;; Grouped shorts: "-abc" → "-a" "-b" "-c", reprocessed.
                    (recur (concat (map (fn [c] (str "-" c)) (rest t)) more)
                           options arguments errors))

                  :else
                  (if in-order
                    {:options options :arguments (into arguments tokens) :errors errors}
                    (recur more options (conj arguments t) errors))))))]
      (let [options (reduce (fn [m sp]
                              (if (and (contains? sp :default-fn)
                                       (not (contains? m (:id sp))))
                                (assoc m (:id sp) ((:default-fn sp) m))
                                m))
                            (:options parsed) specs)
            errors (reduce (fn [es sp]
                             (if (and (contains? sp :missing)
                                      (not (contains? options (:id sp))))
                               (conj es (:missing sp))
                               es))
                           (:errors parsed) specs)]
        {:options options
         :arguments (:arguments parsed)
         :summary (make-summary specs)
         :errors (not-empty errors)}))))
