;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.java.shell API (originally Chris Houser, Stuart Halloway; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.java.shell: run a host program and capture its result (ADR-0199).
;;
;; A thin layer over the native `cljw.process/run`, which spawns by argv vector
;; (never a shell) and returns {:exit :out :err}. This file owns the clj
;; surface: the trailing keyword options, the *sh-dir* / *sh-env* bindings, and
;; the coercions JVM sh accepts (an :in that is not a string is slurped, :dir
;; may be a File, :env values are stringified, an :env may also be a seq of
;; "NAME=value" strings). Text is UTF-8 both ways; :out-enc :bytes returns the
;; stdout bytes, any other named encoding is refused rather than ignored.
(ns clojure.java.shell)

(def ^:dynamic *sh-dir*
  "Working directory for `sh` calls made in this binding, or nil to inherit."
  nil)

(def ^:dynamic *sh-env*
  "Environment map for `sh` calls made in this binding, or nil to inherit."
  nil)

(defmacro with-sh-dir
  "Evaluate body with `sh` running programs in directory dir."
  [dir & body]
  `(binding [*sh-dir* ~dir] ~@body))

(defmacro with-sh-env
  "Evaluate body with `sh` running programs under environment env, which
   replaces the inherited environment."
  [env & body]
  `(binding [*sh-env* ~env] ~@body))

(defn- utf-8? [enc]
  (or (nil? enc) (#{"UTF-8" "utf-8" "UTF8" "utf8"} enc)))

(defn- env-map [env]
  (cond
    (nil? env) nil
    (map? env) (into {} (map (fn [[k v]] [(if (keyword? k) (name k) (str k)) (str v)])) env)
    :else (into {}
                (map (fn [s]
                       (let [s (str s)
                             i (.indexOf s "=")]
                         (if (neg? i)
                           (throw (IllegalArgumentException. (str "sh: an :env entry must be NAME=value, got " (pr-str s))))
                           [(subs s 0 i) (subs s (inc i))]))))
                env)))

(defn sh
  "Run a host program and wait for it to finish.

   args are the program and its arguments as strings, followed by options:
     :in       text for the program's standard input; a non-string is slurped
     :in-enc   encoding of :in (UTF-8 only)
     :out-enc  encoding of stdout: UTF-8 (the default) or :bytes
     :dir      working directory, a string or File
     :env      environment replacing the inherited one: a map, or a seq of
               \"NAME=value\" strings

   Returns {:exit code :out stdout :err stderr}. A non-zero exit is returned,
   not thrown. The program is started directly, never through a shell."
  [& args]
  (let [[cmd opts] (split-with string? args)
        _ (when (empty? cmd)
            (throw (IllegalArgumentException. "sh: the program name must be given as a string")))
        _ (when (odd? (count opts))
            (throw (IllegalArgumentException. (str "sh: options must be key/value pairs, got " (pr-str opts)))))
        {:keys [in in-enc out-enc dir env]
         :or {dir *sh-dir* env *sh-env*}} (apply hash-map opts)]
    (when-not (utf-8? in-enc)
      (throw (IllegalArgumentException. (str "sh: unsupported :in-enc " (pr-str in-enc) "; only UTF-8 is supported"))))
    (when-not (or (utf-8? out-enc) (= :bytes out-enc))
      (throw (IllegalArgumentException. (str "sh: unsupported :out-enc " (pr-str out-enc) "; only UTF-8 and :bytes are supported"))))
    (let [run (or (resolve 'cljw.process/run)
                  (throw (ex-info "sh: this cljw build cannot start host programs (no cljw.process on WASI)"
                                  {:cmd (vec cmd)})))
          res (run (vec cmd)
                   (cond-> {}
                     (some? in) (assoc :in (if (string? in) in (slurp in)))
                     (some? dir) (assoc :dir (str dir))
                     (some? env) (assoc :env (env-map env))))]
      (if (= :bytes out-enc)
        (update res :out #(.getBytes ^String % "UTF-8"))
        res))))
