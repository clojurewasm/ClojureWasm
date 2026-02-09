;; clojure.java.shell — Shell execution via subprocess.
;; UPSTREAM-DIFF: sh is a Zig builtin (std.process.Child), not Runtime.exec().
;; Dynamic vars *sh-dir* and *sh-env* are checked by sh builtin.

(ns clojure.java.shell)

(def ^:dynamic *sh-dir* nil)
(def ^:dynamic *sh-env* nil)

(defmacro with-sh-dir
  "Sets the directory for use with sh, see sh for details."
  [dir & forms]
  `(binding [clojure.java.shell/*sh-dir* ~dir]
     ~@forms))

(defmacro with-sh-env
  "Sets the environment for use with sh, see sh for details."
  [env & forms]
  `(binding [clojure.java.shell/*sh-env* ~env]
     ~@forms))
