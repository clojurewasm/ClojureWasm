;; The java.io / clojure.java.io family (ADR-0126 Cycles 1-5) over the
;; buffer-backed host_stream: java.io.File, the Coercions / IOFactory fns,
;; reader / writer / streams, copy, line-seq, slurp / spit options and errors,
;; the cljw.json / cljw.fs wrappers, and size-0 special files (procfs).
;;
;; Migrated from test/e2e/phase16_{java_io_file,clojure_java_io,
;; clojure_java_io_copy,clojure_java_io_streams,host_stream,file_io_errors,
;; cljw_json_fs,special_file_read,fs_jail}.sh, which paid one process per case.
;; The scripts' marker names are kept in the assertion messages.
;;
;; The FS-jail cases (CLJW_FS_ROOT) configure the PROCESS, so they run in a
;; child cljw with that variable set; nothing else here leaves the process.
;;
;; A cljw class value prints like the JVM class but is not `=` to the class
;; symbol's value for the host stream families, so class identity is asserted
;; by name.
(ns suites.java-io-family-test
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.java.shell :refer [sh]]
            [cljw.json]
            [cljw.fs]))

(def ^:private tmp (str "/tmp/cljw_java_io_family_" (System/currentTimeMillis)))

(defn- p [& parts] (str/join "/" (cons tmp parts)))

(defn- rm-tree! [f]
  (doseq [x (reverse (file-seq (io/file f)))] (.delete x)))

(defn- class-name [x] (.getName (class x)))

(use-fixtures :once
  (fn [run]
    (rm-tree! tmp)
    (.mkdirs (io/file (p "sub")))
    (try (run) (finally (rm-tree! tmp)))))

;; ---- java.io.File (Cycle 1) ----

(deftest java-io-file-type
  (is (= java.io.File (class (java.io.File. "/tmp"))) "class")
  (is (instance? java.io.File (java.io.File. "/tmp")) "instance_pos")
  (is (not (instance? java.io.File 5)) "instance_neg"))

(deftest java-io-file-path-methods
  (is (= "c.txt" (.getName (java.io.File. "/a/b/c.txt"))) "getName")
  (is (= "/a/b/c.txt" (.getPath (java.io.File. "/a/b/c.txt"))) "getPath")
  (is (= "/a/b" (.getParent (java.io.File. "/a/b/c.txt"))) "getParent")
  (is (nil? (.getParent (java.io.File. "x"))) "getParent_nil")
  (is (true? (.isAbsolute (java.io.File. "/a"))) "isAbsolute_t")
  (is (false? (.isAbsolute (java.io.File. "a/b"))) "isAbsolute_f")
  (is (= "/a/b" (str (java.io.File. "/a/b"))) "toString")
  (is (= "b" (.getName (.getParentFile (java.io.File. "/a/b/c")))) "getParentFile")
  (is (= "/a/b/c.txt" (.getAbsolutePath (java.io.File. "/a/b/c.txt"))) "absPath_abs")
  (is (.isAbsolute (java.io.File. (.getAbsolutePath (java.io.File. "rel/x")))) "absPath_rel")
  (is (= "/a/c" (.getCanonicalPath (java.io.File. "/a/./b/../c"))) "canon_dotdot")
  (is (= "/a/b/c.txt" (.getPath (java.io.File. "/a/b" "c.txt"))) "ctor2")
  (is (= "/a/b" (.getPath (java.io.File. (java.io.File. "/a") "b"))) "ctor2_file"))

(deftest java-io-file-fs-methods
  (spit (p "a.txt") "hello\n")
  (is (true? (.exists (java.io.File. (p "a.txt")))) "exists_t")
  (is (false? (.exists (java.io.File. (p "nope")))) "exists_f")
  (is (true? (.isFile (java.io.File. (p "a.txt")))) "isFile_t")
  (is (false? (.isFile (java.io.File. (p "sub")))) "isFile_dir")
  (is (true? (.isDirectory (java.io.File. (p "sub")))) "isDir_t")
  (is (false? (.isDirectory (java.io.File. (p "a.txt")))) "isDir_file")
  (is (= 6 (.length (java.io.File. (p "a.txt")))) "length")
  (is (true? (.canRead (java.io.File. (p "a.txt")))) "canRead")
  (is (true? (.mkdir (java.io.File. (p "d1")))) "mkdir")
  (is (true? (.mkdirs (java.io.File. (p "list" "d3" "d4")))) "mkdirs")
  (is (true? (.delete (java.io.File. (p "d1")))) "delete")
  (is (false? (.delete (java.io.File. (p "never")))) "delete_gone")
  (spit (p "list" "z.txt") "z")
  (is (= ["d3" "z.txt"] (sort (seq (.list (java.io.File. (p "list")))))) "list"))

;; ---- clojure.java.io file family (Cycle 2) ----

(deftest cji-file-and-as-file
  (is (= "/a/b" (.getPath (io/file "/a/b"))) "file_1")
  (is (= "/a/b/c.txt" (.getPath (io/file "/a" "b/c.txt"))) "file_2")
  (is (= "/a/b/c" (.getPath (io/file "/a" "b" "c"))) "file_3")
  (is (instance? java.io.File (io/file "/a")) "file_class")
  (is (= "/x/y" (.getPath (io/as-file "/x/y"))) "as_file_str")
  (is (nil? (io/as-file nil)) "as_file_nil")
  (is (= "/z" (.getPath (io/as-file (io/file "/z")))) "as_file_idem")
  (is (= "a/b" (io/as-relative-path "a/b")) "rel_ok")
  (is (thrown? Throwable (io/as-relative-path "/abs")) "rel_abs_throws"))

(deftest cji-delete-and-make-parents
  (spit (p "del.txt") "x")
  (is (true? (io/delete-file (p "del.txt"))) "delete_ok")
  (is (= :skipped (io/delete-file (p "gone") :skipped)) "delete_silently")
  (is (thrown? Throwable (io/delete-file (p "gone"))) "delete_throws")
  (is (true? (io/make-parents (io/file tmp "d1/d2/leaf.txt"))) "make_parents")
  (is (true? (.isDirectory (io/file (p "d1" "d2")))) "parents_made"))

(deftest cji-as-url-and-resource
  (is (nil? (io/as-url nil)) "as_url_nil")
  (is (= "http://x/y" (str (io/as-url "http://x/y"))) "as_url_str")
  (is (= "file:///a/b" (str (io/as-url (io/file "/a/b")))) "as_url_file")
  (is (instance? java.net.URI (io/as-url "http://x")) "as_url_uri")
  (is (thrown? Throwable (io/as-url 42)) "as_url_bad")
  (spit (p "uri.txt") "uri-body")
  (is (= "uri-body" (slurp (io/reader (java.net.URI. (str "file://" (p "uri.txt"))))))
      "reader_file_uri")
  (is (nil? (io/resource "config.edn")) "resource_nil")
  (is (= :none (if-let [_ (io/resource "x")] :found :none)) "resource_gd"))

(deftest spit-options-and-file-args
  (let [ap (p "ap.txt") ap2 (p "ap2.txt") cc (p "cc.txt")]
    (spit ap "1") (spit ap "2" :append true) (spit ap "3" :append true)
    (is (= "123" (slurp ap)) "spit_append_options: appended")
    (spit ap2 "X" :append true)
    (is (= "X" (slurp ap2)) "spit_append_options: append to a missing file creates it")
    (spit ap "reset" :append false)
    (is (= "reset" (slurp ap)) "spit_append_options: :append false truncates")
    (spit ap "enc" :encoding "UTF-8")
    (is (= "enc" (slurp ap)) "spit_append_options: :encoding accepted")
    (spit cc 42)
    (is (= "42" (slurp cc)) "spit_append_options: content is str-coerced")
    (spit cc {:a 1})
    (is (= "{:a 1}" (slurp cc))))
  (spit (io/file (p "farg.txt")) "filebody")
  (is (= "filebody" (slurp (io/file (p "farg.txt")))) "slurp_spit_file_arg")
  (spit (io/file tmp "sub.txt") "nested")
  (is (= "nested" (slurp (io/file (p "sub.txt")))) "slurp_spit_file_arg: multi-segment File"))

;; ---- reader / writer / streams (Cycle 4) ----

(deftest cji-stream-coercions
  (spit (p "lines.txt") "alpha\nbeta\ngamma\n")
  (let [lines (p "lines.txt")]
    (is (= "java.io.BufferedReader" (class-name (io/reader lines))) "reader_class")
    (is (instance? java.io.Writer (io/writer (p "w.txt"))) "writer_inst")
    (is (instance? java.io.InputStream (io/input-stream lines)) "instream_inst")
    (is (instance? java.io.OutputStream (io/output-stream (p "o.dat"))) "outstream_inst")
    (is (let [r (io/reader lines)] (identical? r (io/reader r))) "reader_idem")
    (is (= "java.io.BufferedReader" (class-name (io/reader (io/file lines)))) "reader_of_file")
    (is (thrown? Throwable (io/reader 42)) "reader_bad")
    (testing "instance? follows the clj class chain (D-358)"
      (is (instance? java.io.BufferedReader (io/reader lines)) "r_concrete")
      (is (instance? java.io.Reader (io/reader lines)) "r_super")
      (is (not (instance? java.io.FileReader (io/reader lines))) "r_sibling")
      (is (not (instance? java.io.PrintWriter (io/writer (p "w2.txt")))) "w_sibling")
      (is (instance? java.io.FilterInputStream (io/input-stream lines)) "is_filter")
      (is (not (instance? java.io.FileInputStream (io/input-stream lines))) "is_sibling")
      (is (not (instance? java.io.OutputStream (io/reader lines))) "r_cross"))))

(deftest imported-simple-class-names
  (spit (p "imp.txt") "x\n")
  (testing "import_simple: (import ...) as its own form, then a bare class name"
    (is (true? (binding [*ns* *ns*]
                 (eval '(ns java-io-family-imp))
                 (eval '(import (quote java.io.BufferedReader)))
                 (eval (list 'instance? 'BufferedReader (list 'clojure.java.io/reader (p "imp.txt"))))))))
  (testing "import_ns_form + import_cross_ns: a fn closing over an (:import) resolves lexically"
    (binding [*ns* *ns*]
      (eval '(ns java-io-family-imp-ns (:import [java.io BufferedReader])))
      (eval '(defn r? [x] (instance? BufferedReader x))))
    (is (true? ((ns-resolve 'java-io-family-imp-ns 'r?) (io/reader (p "imp.txt")))))))

(deftest line-seq-and-with-open
  (spit (p "ls.txt") "alpha\nbeta\ngamma\n")
  (is (= ["alpha" "beta" "gamma"] (vec (line-seq (io/reader (p "ls.txt"))))) "line_seq")
  (with-open [w (io/writer (p "out.txt"))] (.write w "wrote ") (.write w "it"))
  (is (= "wrote it" (slurp (p "out.txt"))) "with_open_writer")
  (spit (p "blank.txt") "a\n\nb\n")
  (is (= 3 (count (line-seq (io/reader (p "blank.txt"))))) "line_seq_blank: blank lines count")
  (spit (p "471.txt") "l1\nl2")
  (is (= "l2" (with-open [r (io/reader (p "471.txt"))] (.readLine r) (slurp r)))
      "slurp_reader_rest: slurp drains the unread remainder")
  (with-open [w (io/writer (p "471b.txt"))] (spit w "via-writer"))
  (is (= "via-writer" (slurp (p "471b.txt"))) "spit_writer"))

;; ---- copy (Cycle 5) ----

(deftest cji-copy
  (spit (p "src.txt") "file-source-bytes")
  (io/copy "from-string" (p "o_str.txt"))
  (is (= "from-string" (slurp (p "o_str.txt"))) "str_to_file")
  (io/copy (io/file (p "src.txt")) (io/file (p "o_file.txt")))
  (is (= "file-source-bytes" (slurp (p "o_file.txt"))) "file_to_file")
  (with-open [w (io/writer (p "o_pass.txt"))] (io/copy (io/reader (p "src.txt")) w))
  (is (= "file-source-bytes" (slurp (p "o_pass.txt"))) "reader_to_passed_writer")
  (with-open [o (io/output-stream (p "o_bin.txt"))] (io/copy (io/input-stream (p "src.txt")) o))
  (is (= "file-source-bytes" (slurp (p "o_bin.txt"))) "instream_to_outstream")
  (is (thrown? Throwable (io/copy 1 (p "x"))) "copy_bad_in")
  (is (thrown? Throwable (io/copy "ok" 2)) "copy_bad_out"))

;; ---- host_stream primitives (Cycle 3) ----

(deftest host-stream-primitives
  (is (= ["a" "bb" "ccc" nil]
         (let [r (cljw.internal/__string-reader "a\nbb\nccc")]
           [(.readLine r) (.readLine r) (.readLine r) (.readLine r)]))
      "readLine_seq")
  (is (= [65 66 -1] (let [r (cljw.internal/__string-reader "AB")] [(.read r) (.read r) (.read r)]))
      "read_byte")
  (is (= "hello world" (cljw.internal/__stream-slurp (cljw.internal/__string-reader "hello world")))
      "slurp_string")
  (is (= ["a" "" "b"] (let [r (cljw.internal/__string-reader "a\n\nb")] [(.readLine r) (.readLine r) (.readLine r)]))
      "blank_lines")
  (is (= "java.io.BufferedReader" (class-name (cljw.internal/__string-reader "x"))) "class_reader")
  (is (instance? java.io.Reader (cljw.internal/__string-reader "x")) "inst_reader")
  (is (not (instance? java.io.Reader 5)) "inst_reader_neg")
  (is (instance? java.io.Writer (cljw.internal/__open-writer (p "hs_w.txt"))) "inst_writer")
  (is (instance? java.io.OutputStream (cljw.internal/__open-output-stream (p "hs_o.dat"))) "inst_outstream")
  (let [w (cljw.internal/__open-writer (p "hs_out.txt"))] (.write w "hello ") (.write w "world") (.close w))
  (is (= "hello world" (slurp (p "hs_out.txt"))) "writer_flush")
  (is (= "hello world" (cljw.internal/__stream-slurp (cljw.internal/__open-reader (p "hs_out.txt"))))
      "reader_file")
  (let [in (cljw.internal/__string-reader "copied!") out (cljw.internal/__open-writer (p "hs_copy.txt"))]
    (cljw.internal/__stream-copy in out)
    (.close out))
  (is (= "copied!" (slurp (p "hs_copy.txt"))) "stream_copy")
  (spit (p "crlf.txt") "x\r\ny\r\n")
  (is (= ["x" "y" nil] (let [r (cljw.internal/__open-reader (p "crlf.txt"))] [(.readLine r) (.readLine r) (.readLine r)]))
      "crlf: readLine strips CRLF"))

;; ---- slurp / spit errors are catchable (io_error Kind) ----

(deftest file-io-errors
  (let [missing "/tmp/cljw_no_such_file_zzz.edn"]
    (is (thrown? Throwable (slurp missing)) "slurp_missing_catchable")
    (is (thrown? java.io.IOException (slurp missing)) "slurp_missing_ioexception")
    (is (thrown? java.io.FileNotFoundException (slurp missing)) "slurp_missing_filenotfound"))
  (is (thrown? Throwable (spit "/cljw_no_such_dir_zzz/x" "y")) "spit_baddir_catchable")
  (is (thrown? java.io.FileNotFoundException (spit "/cljw_no_such_dir_zzz/x" "y")) "spit_baddir_filenotfound")
  (spit (p "rt.txt") "hello")
  (is (= "hello" (slurp (p "rt.txt"))) "slurp_spit_roundtrip"))

;; ---- size-0 special files (CLJW-PROCFS-READ) ----

(deftest special-file-read
  (if-not (.exists (io/file "/proc/version"))
    (is true "no /proc on this host: the file_io unit test covers the shape")
    (do
      (is (pos? (count (slurp "/proc/loadavg"))) "slurp-loadavg")
      (is (pos? (count (slurp "/proc/version"))) "slurp-version")
      (is (pos? (count (with-open [r (io/reader "/proc/loadavg")] (doall (line-seq r))))) "reader-lines")
      (is (pos? (count (slurp (io/file "/proc/version")))) "io-file"))))

;; ---- cljw.json / cljw.fs (ADR-0126 Cycle 7) ----

(deftest cljw-json
  (is (= "{\"a\":1,\"b\":[2,3]}" (cljw.json/encode {:a 1 :b [2 3]})) "json_encode")
  (is (= {:name "x" :nested {:k 1}} (cljw.json/decode "{\"name\":\"x\",\"nested\":{\"k\":1}}")) "json_decode_kw")
  (is (= "(+ 1 2)" (:code (cljw.json/decode "{\"code\":\"(+ 1 2)\"}"))) "json_decode_get")
  (is (= 1 (get (cljw.json/decode-strict "{\"a\":1}") "a")) "json_decode_strict")
  (is (= {:x [1 2 3]} (cljw.json/decode (cljw.json/encode {:x [1 2 3]}))) "json_roundtrip")
  (is (= "X" (with-redefs [clojure.data.json/write-str (fn [& _] "X")] (cljw.json/write-str {:a 1})))
      "json_write_str_redefs: delegates at call time")
  (is (= {:a 1} (cljw.json/read-str "{\"a\":1}" :key-fn keyword)) "json_read_str_opts")
  (is (= '([x & options]) (:arglists (meta #'cljw.json/write-str))) "json_write_str_arglists")
  (is (string? (:doc (meta #'cljw.json/read-str))) "json_read_str_doc"))

(deftest cljw-fs
  (spit (p "ten.txt") "0123456789")
  (is (true? (cljw.fs/exists? (p "ten.txt"))) "fs_exists")
  (is (false? (cljw.fs/exists? (p "nope"))) "fs_exists_no")
  (is (true? (cljw.fs/regular-file? (p "ten.txt"))) "fs_regular")
  (is (true? (cljw.fs/directory? (p "sub"))) "fs_dir")
  (is (= "ten.txt" (cljw.fs/file-name (p "ten.txt"))) "fs_name")
  (is (= 10 (cljw.fs/size (p "ten.txt"))) "fs_size")
  (is (= (p "ten.txt") (cljw.fs/path (p "ten.txt"))) "fs_path")
  (is (true? (cljw.fs/create-dirs (p "a" "b" "c"))) "fs_create_dirs")
  (is (true? (cljw.fs/directory? (p "a" "b" "c"))) "fs_made"))

;; ---- FS jail (ADR-0123): CLJW_FS_ROOT configures the process ----

(defn- jailed
  "Run `expr` in a child cljw whose FS jail is `root`; answer its last stdout line."
  [root expr]
  (let [{:keys [out err]} (sh "zig-out/bin/cljw" "-e" expr
                              :env (assoc (into {} (System/getenv)) "CLJW_FS_ROOT" root))]
    (or (last (str/split-lines out)) err)))

(deftest fs-jail
  (let [jail (p "jail")]
    (.mkdirs (io/file jail))
    (spit (str jail "/inside.txt") "secret-inside")
    (is (= "\"secret-inside\"" (jailed jail "(slurp \"inside.txt\")"))
        "fsjail-confined-read: a jail-relative path resolves under the root")
    (is (= ":escaped" (jailed jail "(try (slurp \"../../../../../etc/hosts\") (catch Throwable _ :escaped))"))
        "fsjail-traversal-rejected")
    (is (= ":escaped" (jailed jail "(try (slurp \"/etc/hosts\") (catch Throwable _ :escaped))"))
        "fsjail-absolute-rejected")
    (jailed jail "(spit \"out.txt\" \"written\")")
    (is (= "written" (slurp (str jail "/out.txt"))) "fsjail-confined-write")
    (is (= ":escaped" (jailed jail "(try (spit \"../escape.txt\" \"x\") (catch Throwable _ :escaped))"))
        "fsjail-write-traversal-rejected")
    (is (not (.exists (io/file (p "escape.txt")))) "fsjail-write-traversal-rejected: nothing written outside")
    (is (= ":blocked" (jailed jail "(try (cljw.internal/__open-reader \"../../../etc/passwd\") (catch Throwable e :blocked))"))
        "jail_escape: the host_stream open path is jailed too")
    (is (= "secret-inside" (slurp (str jail "/inside.txt"))) "fsjail-off-local-unaffected")))
