;; clojure.java.io — polymorphic I/O utilities (ADR-0126). cljw-native shape.
;;
;; JVM clojure.java.io is built on the Coercions + IOFactory protocols extended
;; to String / nil / File / URL / Socket / byte[] / char[]. cljw cannot extend a
;; protocol to String / nil (host_interface.nativeExtendTags reaches only the 4
;; native collection interfaces, ADR-0059), so the coercion/factory entry points
;; are plain fns that dispatch on the coercible kinds with `cond`. This is the
;; documented cljw-style divergence: the surface is NOT user-extensible the way
;; JVM IOFactory is (no realistic cljw caller extends it). Errors raise `ex-info`
;; — the cljw throw idiom (the JVM IllegalArgumentException / IOException ctors
;; are catch-only reservations, not constructable; see compat_tiers.yaml).
;;
;; Cycle 2 (this file as it stands): Coercions (as-file) + file / as-relative-path
;; / delete-file / make-parents over the java.io.File host type. reader / writer /
;; input-stream / output-stream / copy land with the stream host types
;; (ADR-0126 Cycles 3-5). as-url + resource are deferred (no URL type / no
;; classpath).
(ns clojure.java.io)

(defn as-file
  "Coerce x to a java.io.File. String -> (File. x); a File -> itself; nil -> nil."
  [x]
  (cond
    (instance? java.io.File x) x
    (string? x) (java.io.File. x)
    (nil? x) nil
    :else (throw (ex-info (str "Cannot coerce to a java.io.File: " (pr-str x)) {:value x}))))

(defn as-relative-path
  "Take an as-file-able thing and return its path string if it is relative,
   else throw."
  [x]
  (let [f (as-file x)]
    (if (.isAbsolute f)
      (throw (ex-info (str f " is not a relative path") {:path (str f)}))
      (.getPath f))))

(defn file
  "Return a java.io.File, passing each arg through as-file. Multiple-arg
   versions treat the first argument as parent and subsequent args as children
   relative to it."
  ([arg] (as-file arg))
  ([parent child] (java.io.File. (as-file parent) (as-relative-path child)))
  ([parent child & more] (reduce file (file parent child) more)))

(defn delete-file
  "Delete file f. If silently is nil or false, raise on failure; else return the
   value of silently."
  [f & [silently]]
  (or (.delete (as-file f))
      silently
      (throw (ex-info (str "Couldn't delete " f) {:path (str (as-file f))}))))

(defn make-parents
  "Given the same arg(s) as for file, create all parent directories of the file
   they represent."
  [f & more]
  (when-let [parent (.getParentFile (apply file f more))]
    (.mkdirs parent)))
