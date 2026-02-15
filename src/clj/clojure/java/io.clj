;; clojure.java.io — polymorphic I/O utility functions
;;
;; UPSTREAM-DIFF: reader slurps file into PushbackReader (in-memory, not streaming)
;; UPSTREAM-DIFF: writer buffers in memory, writes to file on close
;; UPSTREAM-DIFF: input-stream/output-stream delegate to reader/writer (character-based)
;; UPSTREAM-DIFF: protocol dispatch uses cond (no Java type hierarchy)

(ns clojure.java.io)

;; ========== Coercions protocol ==========

(defprotocol Coercions
  "Coerce between various 'resource-namish' things."
  (as-file [x] "Coerce argument to a file.")
  (as-url [x] "Coerce argument to a URL."))

;; UPSTREAM-DIFF: extend-protocol uses Object with cond dispatch
(extend-protocol Coercions
  Object
  (as-file [x]
    (cond
      (nil? x)    nil
      (string? x) (File. x)
      ;; File instance — return as-is
      (and (map? x) (= "java.io.File" (:__reify_type x))) x
      ;; URI with file scheme
      (and (map? x) (= "java.net.URI" (:__reify_type x)))
      (as-file (as-url x))
      :else (throw (ex-info (str "Cannot coerce to file: " (pr-str x)) {:value x}))))
  (as-url [x]
    (cond
      (nil? x)    nil
      (string? x) (URI. x)
      ;; URI instance — return as-is
      (and (map? x) (= "java.net.URI" (:__reify_type x))) x
      ;; File instance — convert to URI
      (and (map? x) (= "java.io.File" (:__reify_type x)))
      (URI. (str "file:" (.getPath x)))
      :else (throw (ex-info (str "Cannot coerce to URL: " (pr-str x)) {:value x})))))

;; ========== IOFactory protocol ==========

(defprotocol IOFactory
  "Factory functions that create ready-to-use, buffered versions of
   the various Java I/O stream types, on top of anything that can
   be unequivocally converted to the requested kind of stream.

   Common options include

     :append    true to open stream in append mode
     :encoding  string name of encoding to use, e.g. \"UTF-8\".

   Callers should generally prefer the higher level API provided by
   reader, writer, input-stream, and output-stream."
  (make-reader [x opts] "Creates a BufferedReader. See also IOFactory docs.")
  (make-writer [x opts] "Creates a BufferedWriter. See also IOFactory docs.")
  (make-input-stream [x opts] "Creates a BufferedInputStream. See also IOFactory docs.")
  (make-output-stream [x opts] "Creates a BufferedOutputStream. See also IOFactory docs."))

(def default-streams-impl
  "Implementations of IOFactory methods for default types."
  {:make-reader (fn [x opts] (make-reader (make-input-stream x opts) opts))
   :make-writer (fn [x opts] (make-writer (make-output-stream x opts) opts))
   :make-input-stream (fn [x opts]
                        (throw (ex-info (str "Cannot open <" (pr-str x) "> as an InputStream.")
                                        {:value x})))
   :make-output-stream (fn [x opts]
                         (throw (ex-info (str "Cannot open <" (pr-str x) "> as an OutputStream.")
                                         {:value x})))})

;; Helper functions
(defn- append? [opts] (boolean (:append opts)))
(defn- encoding [opts] (or (:encoding opts) "UTF-8"))

;; UPSTREAM-DIFF: Helper to resolve a path from various input types
(defn- resolve-path [x]
  (cond
    (string? x) x
    (and (map? x) (= "java.io.File" (:__reify_type x))) (.getPath x)
    (and (map? x) (= "java.net.URI" (:__reify_type x)))
    (let [scheme (.getScheme x)]
      (if (or (nil? scheme) (= "file" scheme))
        (.getPath x)
        (throw (ex-info (str "Cannot resolve non-file URI to path: " x) {:value x}))))
    :else (str x)))

;; ========== IOFactory implementations ==========

;; UPSTREAM-DIFF: Single Object extension with cond dispatch inside
(extend-protocol IOFactory
  Object
  (make-reader [x opts]
    (cond
      ;; PushbackReader — already a reader
      (and (map? x) (= "java.io.PushbackReader" (:__reify_type x)))
      x
      ;; StringReader — wrap in PushbackReader
      (and (map? x) (= "java.io.StringReader" (:__reify_type x)))
      (PushbackReader. x)
      ;; String — try as file path
      (string? x)
      (let [content (slurp x)]
        (PushbackReader. content))
      ;; File — read and wrap
      (and (map? x) (= "java.io.File" (:__reify_type x)))
      (let [content (slurp (.getPath x))]
        (PushbackReader. content))
      ;; URI — read from path
      (and (map? x) (= "java.net.URI" (:__reify_type x)))
      (make-reader (resolve-path x) opts)
      ;; nil
      (nil? x)
      (throw (ex-info "Cannot open <nil> as a Reader." {}))
      :else
      (throw (ex-info (str "Cannot open <" (pr-str x) "> as a Reader.") {:value x}))))

  (make-writer [x opts]
    (cond
      ;; StringWriter — already a writer
      (and (map? x) (= "java.io.StringWriter" (:__reify_type x)))
      x
      ;; BufferedWriter — already a writer
      (and (map? x) (= "java.io.BufferedWriter" (:__reify_type x)))
      x
      ;; String — open file for writing
      (string? x)
      (BufferedWriter. x (append? opts))
      ;; File — write to path
      (and (map? x) (= "java.io.File" (:__reify_type x)))
      (BufferedWriter. (.getPath x) (append? opts))
      ;; URI — write to path
      (and (map? x) (= "java.net.URI" (:__reify_type x)))
      (make-writer (resolve-path x) opts)
      ;; nil
      (nil? x)
      (throw (ex-info "Cannot open <nil> as a Writer." {}))
      :else
      (throw (ex-info (str "Cannot open <" (pr-str x) "> as a Writer.") {:value x}))))

  (make-input-stream [x opts]
    ;; UPSTREAM-DIFF: delegates to make-reader (CW doesn't have separate byte streams)
    (make-reader x opts))

  (make-output-stream [x opts]
    ;; UPSTREAM-DIFF: delegates to make-writer (CW doesn't have separate byte streams)
    (make-writer x opts)))

;; ========== Public API ==========

(defn reader
  "Attempts to coerce its argument into an open java.io.Reader.
  Default implementations always return a java.io.BufferedReader.

  Default implementations are provided for Reader, BufferedReader,
  InputStream, File, URI, URL, Socket, byte arrays, character arrays,
  and String.

  If argument is a String, it tries to resolve it first as a URI, then
  as a local file name. URIs with a 'file' protocol are converted to
  local file names.

  Should be used inside with-open to ensure the Reader is properly
  closed."
  {:added "1.2"}
  [x & opts]
  (make-reader x (when opts (apply hash-map opts))))

(defn writer
  "Attempts to coerce its argument into an open java.io.Writer.
  Default implementations always return a java.io.BufferedWriter.

  Default implementations are provided for Writer, BufferedWriter,
  OutputStream, File, URI, URL, Socket, and String.

  If the argument is a String, it tries to resolve it first as a URI, then
  as a local file name. URIs with a 'file' protocol are converted to
  local file names.

  Should be used inside with-open to ensure the Writer is properly
  closed."
  {:added "1.2"}
  [x & opts]
  (make-writer x (when opts (apply hash-map opts))))

(defn input-stream
  "Attempts to coerce its argument into an open java.io.InputStream.
  Default implementations always return a java.io.BufferedInputStream.

  Default implementations are defined for InputStream, File, URI, URL,
  Socket, byte array, and String arguments.

  If the argument is a String, it tries to resolve it first as a URI, then
  as a local file name. URIs with a 'file' protocol are converted to
  local file names.

  Should be used inside with-open to ensure the InputStream is properly
  closed."
  {:added "1.2"}
  [x & opts]
  (make-input-stream x (when opts (apply hash-map opts))))

(defn output-stream
  "Attempts to coerce its argument into an open java.io.OutputStream.
  Default implementations always return a java.io.BufferedOutputStream.

  Default implementations are defined for OutputStream, File, URI, URL,
  Socket, and String arguments.

  If the argument is a String, it tries to resolve it first as a URI, then
  as a local file name. URIs with a 'file' protocol are converted to
  local file names.

  Should be used inside with-open to ensure the OutputStream is
  properly closed."
  {:added "1.2"}
  [x & opts]
  (make-output-stream x (when opts (apply hash-map opts))))
