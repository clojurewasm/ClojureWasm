;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: CW-compatible fork of clojure.tools.cli
;; Upstream: clojure/tools.cli (Gareth Jones, Sung Pae, Sean Corfield)
;; UPSTREAM-DIFF: Resolved reader conditionals for :clj platform.
;; Replaced Throwable with Exception in catch blocks.
;; Removed #?(:cljr ...) CLR-specific code.

(ns ^{:author "Gareth Jones, Sung Pae, Sean Corfield, CW fork"
      :doc "Tools for working with command line arguments.
  CW fork: reader conditionals resolved for :clj platform."}
 clojure.tools.cli
  (:require [clojure.string :as s]))

;;
;; Utility Functions:
;;

(defn- make-format
  "Given a sequence of column widths, return a string suitable for use in
  format to print a sequences of strings in those columns."
  [lens]
  (s/join (map #(str "  %" (when-not (zero? %) (str "-" %)) "s") lens)))

(defn- tokenize-args
  "Reduce arguments sequence into [opt-type opt ?optarg?] vectors and a vector
  of remaining arguments. Returns as [option-tokens remaining-args].

  Expands clumped short options like \"-abc\" into:
  [[:short-opt \"-a\"] [:short-opt \"-b\"] [:short-opt \"-c\"]]

  If \"-b\" were in the set of options that require arguments, \"-abc\" would
  then be interpreted as: [[:short-opt \"-a\"] [:short-opt \"-b\" \"c\"]]

  Long options with `=` are always parsed as option + optarg, even if nothing
  follows the `=` sign.

  If the :in-order flag is true, the first non-option, non-optarg argument
  stops options processing. This is useful for handling subcommand options."
  [required-set args & options]
  (let [{:keys [in-order]} (apply hash-map options)]
    (loop [opts [] argv [] [car & cdr] args]
      (if car
        (condp re-seq car
          ;; Double dash always ends options processing
          #"^--$" (recur opts (into argv cdr) [])
          ;; Long options with assignment always passes optarg, required or not
          ;; CLJW: ^--\S+= → ^--[^=\s]+= (CW regex engine lacks backtracking for \S+)
          #"^--[^=\s]+=" (recur (conj opts (into [:long-opt] (s/split car #"=" 2)))
                                argv cdr)
          ;; Long options, consumes cdr head if needed
          #"^--" (let [[optarg cdr] (if (contains? required-set car)
                                      [(first cdr) (rest cdr)]
                                      [nil cdr])]
                   (recur (conj opts (into [:long-opt car] (if optarg [optarg] [])))
                          argv cdr))
          ;; Short options, expands clumped opts until an optarg is required
          #"^-." (let [[os cdr] (loop [os [] [c & cs] (rest car)]
                                  (let [o (str \- c)]
                                    (if (contains? required-set o)
                                      (if (seq cs)
                                        ;; Get optarg from rest of car
                                        [(conj os [:short-opt o (s/join cs)]) cdr]
                                        ;; Get optarg from head of cdr
                                        [(conj os [:short-opt o (first cdr)]) (rest cdr)])
                                      (if (seq cs)
                                        (recur (conj os [:short-opt o]) cs)
                                        [(conj os [:short-opt o]) cdr]))))]
                   (recur (into opts os) argv cdr))
          (if in-order
            (recur opts (into argv (cons car cdr)) [])
            (recur opts (conj argv car) cdr)))
        [opts argv]))))

(def ^{:private true} spec-keys
  [:id :short-opt :long-opt :required :desc
   :default :default-desc :default-fn
   :parse-fn :assoc-fn :update-fn :multi :post-validation
   :validate-fn :validate-msg :missing])

(defn- select-spec-keys
  "Select only known spec entries from map and warn the user about unknown
   entries at development time."
  [map]
  (when *assert*
    (let [unknown-keys (keys (apply dissoc map spec-keys))]
      (when (seq unknown-keys)
        (let [msg (str "Warning: The following options to parse-opts are unrecognized: "
                       (s/join ", " unknown-keys))]
          ;; CLJW: resolved #?(:clj ...) reader conditional
          (binding [*out* *err*] (println msg))))))

  (select-keys map spec-keys))

(defn- compile-spec [spec]
  (let [sopt-lopt-desc (take-while #(or (string? %) (nil? %)) spec)
        spec-map (apply hash-map (drop (count sopt-lopt-desc) spec))
        [short-opt long-opt desc] sopt-lopt-desc
        long-opt (or long-opt (:long-opt spec-map))
        [long-opt req] (when long-opt
                         (rest (re-find #"^(--[^ =]+)(?:[ =](.*))?" long-opt)))
        id (when long-opt
             (keyword (nth (re-find #"^--(\[no-\])?(.*)" long-opt) 2)))
        validate (:validate spec-map)
        ;; CLJW: (apply map vector colls) doesn't work in CW, use mapv directly
        pairs (when (seq validate) (partition 2 2 (repeat nil) validate))
        validate-fn (when pairs (mapv first pairs))
        validate-msg (when pairs (mapv second pairs))]
    (merge {:id id
            :short-opt short-opt
            :long-opt long-opt
            :required req
            :desc desc
            :validate-fn validate-fn
            :validate-msg validate-msg}
           (select-spec-keys (dissoc spec-map :validate)))))

(defn- distinct?* [coll]
  (if (seq coll)
    (apply distinct? coll)
    true))

(defn- wrap-val [map key]
  (if (contains? map key)
    (update-in map [key] #(cond (nil? %) nil
                                (coll? %) %
                                :else [%]))
    map))

(defn- compile-option-specs
  "Map a sequence of option specification vectors to a sequence of compiled
  option spec maps."
  [option-specs]
  {:post [(every? :id %)
          (distinct?* (map :id (filter :default %)))
          (distinct?* (map :id (filter :default-fn %)))
          (distinct?* (remove nil? (map :short-opt %)))
          (distinct?* (remove nil? (map :long-opt %)))
          (every? (comp not (partial every? identity))
                  (map (juxt :assoc-fn :update-fn) %))]}
  (map (fn [spec]
         (-> (if (map? spec)
               (select-spec-keys spec)
               (compile-spec spec))
             (wrap-val :validate-fn)
             (wrap-val :validate-msg)))
       option-specs))

(defn- default-option-map [specs default-key]
  (reduce (fn [m s]
            (if (contains? s default-key)
              (assoc m (:id s) (default-key s))
              m))
          {} specs))

(defn- missing-errors
  "Given specs, returns a map of spec id to error message if missing."
  [specs]
  (reduce (fn [m s]
            (if (:missing s)
              (assoc m (:id s) (:missing s))
              m))
          {} specs))

(defn- find-spec [specs opt-type opt]
  (first
   (filter
    (fn [spec]
      (when-let [spec-opt (get spec opt-type)]
        (let [flag-tail (second (re-find #"^--\[no-\](.*)" spec-opt))
              candidates (if flag-tail
                           #{(str "--" flag-tail) (str "--no-" flag-tail)}
                           #{spec-opt})]
          (contains? candidates opt))))
    specs)))

(defn- pr-join [& xs]
  (pr-str (s/join \space xs)))

(defn- missing-required-error [opt example-required]
  (str "Missing required argument for " (pr-join opt example-required)))

(defn- parse-error [opt optarg msg]
  (str "Error while parsing option " (pr-join opt optarg) ": " msg))

(defn- validation-error [value opt optarg msg]
  (str "Failed to validate " (pr-join opt optarg)
       (if msg (str ": " (if (string? msg) msg (msg value))) "")))

(defn- validate [value spec opt optarg]
  (let [{:keys [validate-fn validate-msg]} spec]
    (or (loop [[vfn & vfns] validate-fn [msg & msgs] validate-msg]
          (when vfn
            ;; CLJW: Throwable → Exception
            ;; CLJW: catch needs body expression in CW
            (if (try (vfn value) (catch Exception e nil))
              (recur vfns msgs)
              [::error (validation-error value opt optarg msg)])))
        [value nil])))

(defn- parse-value [value spec opt optarg]
  (let [{:keys [parse-fn]} spec
        [value error] (if parse-fn
                        (try
                          [(parse-fn value) nil]
                          ;; CLJW: Throwable → Exception
                          (catch Exception e
                            [nil (parse-error opt optarg (str e))]))
                        [value nil])]
    (cond error
          [::error error]
          (:post-validation spec)
          [value nil]
          :else
          (validate value spec opt optarg))))

(defn- allow-no? [spec]
  (and (:long-opt spec)
       (re-find #"^--\[no-\]" (:long-opt spec))))

(defn- neg-flag? [spec opt]
  (and (allow-no? spec)
       (re-find #"^--no-" opt)))

(defn- parse-optarg [spec opt optarg]
  (let [{:keys [required]} spec]
    (if (and required (nil? optarg))
      [::error (missing-required-error opt required)]
      (let [value (if required
                    optarg
                    (not (neg-flag? spec opt)))]
        (parse-value value spec opt optarg)))))

(defn- parse-option-tokens
  "Reduce sequence of [opt-type opt ?optarg?] tokens into a map of
  {option-id value} merged over the default values in the option
  specifications.

  If the :no-defaults flag is true, only options specified in the tokens are
  included in the option-map.

  Unknown options, missing options, missing required arguments, option
  argument parsing exceptions, and validation failures are collected into
  a vector of error message strings.

  If the :strict flag is true, required arguments that match other options
  are treated as missing, instead of a literal value beginning with - or --.

  Returns [option-map error-messages-vector]."
  [specs tokens & options]
  (let [{:keys [no-defaults strict]} (apply hash-map options)
        defaults (default-option-map specs :default)
        default-fns (default-option-map specs :default-fn)
        requireds (missing-errors specs)]
    (-> (reduce
         (fn [[m ids errors] [opt-type opt optarg]]
           (if-let [spec (find-spec specs opt-type opt)]
             (let [[value error] (parse-optarg spec opt optarg)
                   id (:id spec)]
               (if-not (= value ::error)
                 (if (and strict
                          (or (find-spec specs :short-opt optarg)
                              (find-spec specs :long-opt optarg)))
                   [m ids (conj errors (missing-required-error opt (:required spec)))]
                   (let [m' (if-let [update-fn (:update-fn spec)]
                              (if (:multi spec)
                                (update m id update-fn value)
                                (update m id update-fn))
                              ((:assoc-fn spec assoc) m id value))]
                     (if (:post-validation spec)
                       (let [[value error] (validate (get m' id) spec opt optarg)]
                         (if (= value ::error)
                           [m ids (conj errors error)]
                           [m' (conj ids id) errors]))
                       [m' (conj ids id) errors])))
                 [m ids (conj errors error)]))
             [m ids (conj errors (str "Unknown option: " (pr-str opt)))]))
         [defaults [] []] tokens)
        (#(reduce
           (fn [[m ids errors] [id error]]
             (if (contains? m id)
               [m ids errors]
               [m ids (conj errors error)]))
           % requireds))
        (#(reduce
           (fn [[m ids errors] [id f]]
             (if (contains? (set ids) id)
               [m ids errors]
               [(assoc m id (f (first %))) ids errors]))
           % default-fns))
        (#(let [[m ids errors] %]
            (if no-defaults
              [(select-keys m ids) errors]
              [m errors]))))))

(defn make-summary-part
  "Given a single compiled option spec, turn it into a formatted string,
  optionally with its default values if requested."
  [show-defaults? spec]
  (let [{:keys [short-opt long-opt required desc
                default default-desc default-fn]} spec
        opt (cond (and short-opt long-opt) (str short-opt ", " long-opt)
                  long-opt (str "    " long-opt)
                  short-opt short-opt)
        [opt dd] [(if required
                    (str opt \space required)
                    opt)
                  (or default-desc
                      (when (contains? spec :default)
                        (if (some? default)
                          (str default)
                          "nil"))
                      (when default-fn
                        "<computed>")
                      "")]]
    (if show-defaults?
      [opt dd (or desc "")]
      [opt (or desc "")])))

(defn format-lines
  "Format a sequence of summary parts into columns. lens is a sequence of
  lengths to use for parts. There are two sequences of lengths if we are
  not displaying defaults. There are three sequences of lengths if we
  are showing defaults."
  [lens parts]
  (let [fmt (make-format lens)]
    (map #(s/trimr (apply format fmt %)) parts)))

(defn- required-arguments [specs]
  (reduce
   (fn [s {:keys [required short-opt long-opt]}]
     (if required
       (into s (remove nil? [short-opt long-opt]))
       s))
   #{} specs))

(defn summarize
  "Reduce options specs into a options summary for printing at a terminal."
  [specs]
  (if (seq specs)
    (let [show-defaults? (some #(or (contains? % :default)
                                    (contains? % :default-fn)) specs)
          parts (map (partial make-summary-part show-defaults?) specs)
          ;; CLJW: (apply map f colls) doesn't work — transpose manually
          lens (let [n (count (first parts))]
                 (mapv (fn [i] (apply max (map #(count (nth % i)) parts)))
                       (range n)))
          lines (format-lines lens parts)]
      (s/join \newline lines))
    ""))

(defn get-default-options
  "Extract the map of default options from a sequence of option vectors."
  [option-specs]
  (let [specs (compile-option-specs option-specs)
        vals  (default-option-map specs :default)]
    (reduce (fn [m [id f]]
              (if (contains? m id)
                m
                (update-in m [id] (f vals))))
            vals
            (default-option-map specs :default-fn))))

(defn parse-opts
  "Parse arguments sequence according to given option specifications and the
  GNU Program Argument Syntax Conventions.

  parse-opts returns a map with four entries:

    {:options     The options map, keyed by :id, mapped to the parsed value
     :arguments   A vector of unprocessed arguments
     :summary     A string containing a minimal options summary
     :errors      A possible vector of error message strings generated during
                  parsing; nil when no errors exist}"
  [args option-specs & options]
  (let [{:keys [in-order no-defaults strict summary-fn]} (apply hash-map options)
        specs (compile-option-specs option-specs)
        req (required-arguments specs)
        [tokens rest-args] (tokenize-args req args :in-order in-order)
        [opts errors] (parse-option-tokens specs tokens
                                           :no-defaults no-defaults :strict strict)]
    {:options opts
     :arguments rest-args
     :summary ((or summary-fn summarize) specs)
     :errors (when (seq errors) errors)}))

;;
;; Legacy API
;;

(defn- build-doc [{:keys [switches docs default]}]
  [(apply str (interpose ", " switches))
   (or (str default) "")
   (or docs "")])

(defn- banner-for [desc specs]
  (when desc
    (println desc)
    (println))
  (let [docs (into (map build-doc specs)
                   [["--------" "-------" "----"]
                    ["Switches" "Default" "Desc"]])
        ;; CLJW: (apply map f colls) doesn't work — transpose manually
        counts (mapv (fn [d] (mapv count d)) docs)
        max-cols (let [n (count (first counts))]
                   (mapv (fn [i] (apply max (map #(nth % i) counts)))
                         (range n)))
        vs (for [d docs]
             (mapcat (fn [& x] (apply vector x)) max-cols d))]
    (doseq [v vs]
      (let [fmt (make-format (take-nth 2 v))]
        (print (apply format fmt (take-nth 2 (rest v)))))
      (prn))))

(defn- name-for [k]
  (s/replace k #"^--no-|^--\[no-\]|^--|^-" ""))

(defn- flag-for [^String v]
  (not (s/starts-with? v "--no-")))

(defn- opt? [^String x]
  (s/starts-with? x "-"))

(defn- flag? [^String x]
  (s/starts-with? x "--[no-]"))

(defn- end-of-args? [x]
  (= "--" x))

(defn- spec-for
  [arg specs]
  (->> specs
       (filter (fn [s]
                 (let [switches (set (s :switches))]
                   (contains? switches arg))))
       first))

(defn- default-values-for
  [specs]
  (reduce (fn [m s]
            (if (contains? s :default)
              ((:assoc-fn s) m (:name s) (:default s))
              m))
          {} specs))

(defn- apply-specs
  [specs args]
  (loop [options    (default-values-for specs)
         extra-args []
         args       args]
    (if-not (seq args)
      [options extra-args]
      (let [opt  (first args)
            spec (spec-for opt specs)]
        (cond
          (end-of-args? opt)
          (recur options (into extra-args (vec (rest args))) nil)

          (and (opt? opt) (nil? spec))
          ;; CLJW: Exception. constructor
          (throw (Exception. (str "'" opt "' is not a valid argument")))

          (and (opt? opt) (spec :flag))
          (recur ((spec :assoc-fn) options (spec :name) (flag-for opt))
                 extra-args
                 (rest args))

          (opt? opt)
          (recur ((spec :assoc-fn) options (spec :name) ((spec :parse-fn) (second args)))
                 extra-args
                 (drop 2 args))

          :else
          (recur options (conj extra-args (first args)) (rest args)))))))

(defn- switches-for
  [switches flag]
  (-> (for [^String s switches]
        (cond (and flag (flag? s))
              [(s/replace s #"\[no-\]" "no-") (s/replace s #"\[no-\]" "")]

              (and flag (s/starts-with? s "--"))
              [(s/replace s #"--" "--no-") s]

              :else
              [s]))
      flatten))

(defn- generate-spec
  [raw-spec]
  (let [[switches raw-spec] (split-with #(and (string? %) (opt? %)) raw-spec)
        [docs raw-spec]     (split-with string? raw-spec)
        options             (apply hash-map raw-spec)
        aliases             (map name-for switches)
        flag                (or (flag? (last switches)) (options :flag))]
    (merge {:switches (switches-for switches flag)
            :docs     (first docs)
            :aliases  (set aliases)
            :name     (keyword (last aliases))
            :parse-fn identity
            :assoc-fn assoc
            :flag     flag}
           (when flag {:default false})
           options)))

(defn- normalize-args
  "Rewrite arguments sequence into a normalized form that is parsable by cli."
  [specs args]
  (let [required-opts (->> specs
                           (filter (complement :flag))
                           (mapcat :switches)
                           (into #{}))
        ;; Preserve double-dash since this is a pre-processing step
        largs (take-while (partial not= "--") args)
        rargs (drop (count largs) args)
        [opts largs] (tokenize-args required-opts largs)]
    (concat (mapcat rest opts) largs rargs)))

(defn ^{:deprecated "since 0.4.x"} cli
  "THIS IS A LEGACY FUNCTION and is deprecated. Please use
  clojure.tools.cli/parse-opts in new applications."
  [args & specs]
  (let [[desc specs] (if (string? (first specs))
                       [(first specs) (rest specs)]
                       [nil specs])
        specs (map generate-spec specs)
        args (normalize-args specs args)
        [options extra-args] (apply-specs specs args)
        banner (with-out-str (banner-for desc specs))]
    [options extra-args banner]))
