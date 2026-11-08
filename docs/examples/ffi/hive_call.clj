;; Call a native library through the hive C ABI with cljw.ffi (ADR-0202).
;;
;; Any shared library that exports
;;
;;   char *hive_call(const char *op, const char *json);
;;   void  hive_free(char *);
;;
;; answers a JSON envelope {"ok": true, "value": ...} or {"ok": false,
;; "error": ...}. Go (c-shared), Rust (cdylib), C and Zig libraries all speak
;; it, and cljw calls them directly: no per-library binding, no wasm rebuild.
;;
;;   cljw -M docs/examples/ffi/hive_call.clj /path/to/libvectorcraft.so ops
(require '[cljw.ffi :as ffi]
         '[clojure.data.json :as json])

(defn hive-library
  "Open `path` and return a fn of [op payload-map] -> decoded envelope."
  [path]
  (let [lib (ffi/open path)
        ;; :pointer, not :string: the callee allocates the answer, so we copy
        ;; it out with ffi/string and hand it back to the library's own free.
        call (ffi/function lib "hive_call" [:string :string] :pointer)
        free (ffi/function lib "hive_free" [:pointer] :void)]
    (fn [op payload]
      (let [p (call op (json/write-str payload))]
        (try
          (json/read-str (ffi/string p) :key-fn keyword)
          (finally (free p)))))))

(let [[path op] *command-line-args*
      hive (hive-library path)]
  (prn (hive (or op "ops") {})))
