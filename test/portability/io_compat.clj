;; Portability test: I/O and System interop
;; This file should produce identical output on JVM Clojure and ClojureWasm.
;; Run: clj -M test/portability/io_compat.clj
;; Run: cljw test/portability/io_compat.clj

(require '[clojure.java.io :as io])

;; --- File path operations ---
(println "file1:" (str (io/file "src" "main")))
(println "file2:" (str (io/file "hello.txt")))
(println "as-file:" (str (io/as-file "test.txt")))

;; --- Relative path ---
(println "relative:" (io/as-relative-path "foo/bar.txt"))
(println "relative-check:" (try (io/as-relative-path "/absolute")
                                (catch Exception e "caught")))

;; --- make-parents, spit, slurp, copy, delete ---
(io/make-parents "/tmp/cljw_compat_test/sub/file.txt")
(spit "/tmp/cljw_compat_test/sub/source.txt" "hello from portability test")
(println "slurp:" (slurp "/tmp/cljw_compat_test/sub/source.txt"))
(io/copy (io/file "/tmp/cljw_compat_test/sub/source.txt")
         (io/file "/tmp/cljw_compat_test/sub/copy.txt"))
(println "copy:" (slurp "/tmp/cljw_compat_test/sub/copy.txt"))

;; --- Cleanup ---
(io/delete-file "/tmp/cljw_compat_test/sub/source.txt")
(io/delete-file "/tmp/cljw_compat_test/sub/copy.txt")
(io/delete-file "/tmp/cljw_compat_test/sub")
(io/delete-file "/tmp/cljw_compat_test")
(println "cleanup: done")

;; --- System properties ---
(println "user.home-exists:" (some? (System/getProperty "user.home")))
(println "os.name-exists:" (some? (System/getProperty "os.name")))
(println "file.sep:" (System/getProperty "file.separator"))
(println "path.sep:" (System/getProperty "path.separator"))
(println "line.sep:" (pr-str (System/getProperty "line.separator")))
(println "default:" (System/getProperty "nonexistent.key" "fallback"))

;; --- Environment ---
(println "env-home:" (some? (System/getenv "HOME")))
(println "env-nil:" (nil? (System/getenv "CLJW_NONEXISTENT_12345")))

;; --- Time ---
(println "nano-pos:" (> (System/nanoTime) 0))
(println "millis-pos:" (> (System/currentTimeMillis) 0))

(println "--- DONE ---")
