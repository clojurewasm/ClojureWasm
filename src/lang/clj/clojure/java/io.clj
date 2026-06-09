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

;; --- IOFactory coercions (ADR-0126 Cycle 4) ---------------------------------
;; reader/writer/input-stream/output-stream coerce a String path / File / an
;; already-open stream into a buffer-backed host_stream (host_stream.zig). The
;; JVM IOFactory protocol over String/File/URL/Socket/byte[] is replaced by cond
;; dispatch (cljw cannot extend a protocol to String, ADR-0059). The String arm
;; opens a FILE at that path (URI resolution + as-url are deferred — no URL type);
;; encoding/append/buffer-size opts are accepted-and-ignored (the model is
;; buffer-backed UTF-8). Use (java.io.StringReader-style) rt/__string-reader for
;; a reader over string CONTENT.

(defn reader
  "Coerce x into an open java.io.Reader. A String/File names a file to open; an
   existing Reader is returned as-is. Use inside with-open."
  [x & opts]
  (cond
    (instance? java.io.Reader x) x
    (instance? java.io.File x)   (rt/__open-reader (.getPath x))
    (string? x)                  (rt/__open-reader x)
    :else (throw (ex-info (str "Cannot open as a java.io.Reader: " (pr-str x)) {:value x}))))

(defn writer
  "Coerce x into an open java.io.Writer (truncating). A String/File names the
   target file; an existing Writer is returned as-is. Use inside with-open."
  [x & opts]
  (cond
    (instance? java.io.Writer x) x
    (instance? java.io.File x)   (rt/__open-writer (.getPath x))
    (string? x)                  (rt/__open-writer x)
    :else (throw (ex-info (str "Cannot open as a java.io.Writer: " (pr-str x)) {:value x}))))

(defn input-stream
  "Coerce x into an open java.io.InputStream. A String/File names a file; an
   existing InputStream is returned as-is. Use inside with-open."
  [x & opts]
  (cond
    (instance? java.io.InputStream x) x
    (instance? java.io.File x)        (rt/__open-input-stream (.getPath x))
    (string? x)                       (rt/__open-input-stream x)
    :else (throw (ex-info (str "Cannot open as a java.io.InputStream: " (pr-str x)) {:value x}))))

(defn output-stream
  "Coerce x into an open java.io.OutputStream (truncating). A String/File names
   the target; an existing OutputStream is returned as-is. Use inside with-open."
  [x & opts]
  (cond
    (instance? java.io.OutputStream x) x
    (instance? java.io.File x)         (rt/__open-output-stream (.getPath x))
    (string? x)                        (rt/__open-output-stream x)
    :else (throw (ex-info (str "Cannot open as a java.io.OutputStream: " (pr-str x)) {:value x}))))

;; `(copy input output & opts)` — copy input to output, returns nil. Input may be
;; a Reader / InputStream, a File, or a String (the String's CONTENT, matching
;; JVM do-copy's StringReader arm). Output may be a Writer / OutputStream, a File,
;; or a String (a file PATH — a cljw convenience; JVM has no String output arm,
;; so note the input=content / output=path asymmetry). Like JVM copy, only a
;; stream copy itself opened (a File/String arg) is closed; a passed stream is
;; the caller's to close. The :buffer-size / :encoding opts are accepted-and-
;; ignored (the transfer is a single Zig []u8 bulk move, UTF-8 throughout).
(defn copy
  [input output & opts]
  (let [in  (cond
              (instance? java.io.Reader input)      input
              (instance? java.io.InputStream input) input
              (instance? java.io.File input)        (reader input)
              (string? input)                       (rt/__string-reader input)
              :else (throw (ex-info (str "copy: cannot read from " (pr-str input)) {:value input})))
        out (cond
              (instance? java.io.Writer output)       output
              (instance? java.io.OutputStream output) output
              (instance? java.io.File output)         (writer output)
              (string? output)                        (rt/__open-writer output)
              :else (throw (ex-info (str "copy: cannot write to " (pr-str output)) {:value output})))
        own? (or (instance? java.io.File output) (string? output))]
    (rt/__stream-copy in out)
    (when own? (.close out))
    nil))
