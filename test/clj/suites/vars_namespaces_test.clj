;; Vars, dynamic binding and namespaces as runtime values (D-230/D-232/D-235/
;; D-237/D-239/D-554, ADR-0083/0085/0096/0097/0171, AD-010/AD-015/AD-053).
;;
;; Migrated from the phase15 e2e scripts alias, var_get_set, dynamic_var,
;; with_local_vars, set_bang, ns_binding_roundtrip, ns_runtime_fns, namespace,
;; ns_docstring, campaign_keywords, use_refer_all, use_libspec_filter,
;; require_runtime_fn, ns_import, import_macro, aliased_macro. Each script ran
;; one `cljw -e` program per case; here a case that needs top-level forms
;; (ns / def / in-ns) evaluates them with `ev`, a load-string inside a FRESH
;; scratch namespace, so a case never leaks its ns switch or defs into the
;; suite (memory 20260911151735: in-ns under a test runner must go through a
;; *ns* binding). Every namespace and var a case creates is prefixed p15-.
(ns suites.vars-namespaces-test
  (:require [clojure.test :refer [deftest is testing]]))

(def ^:private scratch-seq (atom 0))

(defn- ev
  "load-string `src` in a fresh namespace that refers clojure.core, the way
  `cljw -e` evaluated it in `user`. *ns* is thread-bound around it, so the
  program's own ns / in-ns switches pop when it returns."
  [src]
  (let [n (symbol (str "p15.scratch" (swap! scratch-seq inc)))]
    (binding [*ns* (create-ns n)]
      (refer 'clojure.core)
      (load-string src))))

(deftest p15-alias
  (testing "phase15_alias"
    (is (= "HI" (ev "(alias (quote str) (quote clojure.string)) (str/upper-case \"hi\")")) "alias-use")
    (is (true? (ev "(do (alias (quote s) (quote clojure.set)) (contains? (ns-aliases *ns*) (quote s)))")) "ns-aliases")
    (is (= 'clojure.walk (ev "(do (alias (quote w) (quote clojure.walk)) (ns-name ((ns-aliases *ns*) (quote w))))")) "alias-target")
    (is (thrown-with-msg? Throwable #"Could not locate" (ev "(alias (quote x) (quote no.such.ns))")) "alias-unknown")))

(def ^:dynamic *p15-x* 0)

(deftest p15-var-get-set
  (testing "phase15_var_get_set"
    (is (= 5 (ev "(def y 5) (var-get (var y))")) "var-get-root")
    (is (= 7 (ev "(def y 7) (var-get #'y)")) "var-get-hash")
    (is (= 9 (binding [*p15-x* 1] (var-set (var *p15-x*) 9) *p15-x*)) "var-set-bind")
    (is (= 9 (binding [*p15-x* 1] (var-set (var *p15-x*) 9))) "var-set-ret")
    (is (= 0 (do (binding [*p15-x* 1] (var-set (var *p15-x*) 9)) *p15-x*)) "var-set-frame")
    (is (thrown-with-msg? Throwable #"not thread-bound" (var-set (var *p15-x*) 9)) "var-set-unbd")))

(deftest p15-dynamic-var
  (testing "phase15_dynamic_var"
    (is (= 2 (ev "(do (def ^:dynamic *x* 1) (binding [*x* 2] *x*))")) "bind")
    (is (= [2 1] (ev "(do (def ^:dynamic *x* 1) [(binding [*x* 2] *x*) *x*])")) "restore")
    (is (= 30 (ev "(do (def ^:dynamic *y* 10) (binding [*y* 20] (binding [*y* 30] *y*)))")) "nested")
    (is (= [:inner :root] (ev "(do (def ^:dynamic *a* :root) (defn pa [] *a*) [(binding [*a* :inner] (pa)) (pa)])")) "fn-sees")
    (is (thrown-with-msg? Throwable #"non-dynamic" (ev "(do (def plain 1) (binding [plain 2] plain))")) "guard"))
  (testing "core version / flag vars"
    (is (= 12 (:minor *clojure-version*)) "cv_minor")
    (is (= "1.12.0" (clojure-version)) "cv_string")
    (is (false? *unchecked-math*) "unchecked")
    (is (true? (binding [*unchecked-math* true] *unchecked-math*)) "um_bind")))

(deftest p15-with-local-vars
  (testing "phase15_with_local_vars"
    (is (= 12 (with-local-vars [x 1 y 2] (var-set x 10) (+ (var-get x) (var-get y)))) "basic")
    (is (= 20 (with-local-vars [a 5] (var-set a (* @a 4)) @a)) "deref")
    (is (= 99 (with-local-vars [x 1] (var-set x 99))) "set-ret")
    (is (= 3 (with-local-vars [x 1] (with-local-vars [y 2] (+ (var-get x) (var-get y))))) "nested")
    ;; AD-015 pin: an escaped local var deref'd after its extent is nil in cljw.
    (is (nil? (var-get (with-local-vars [x 5] x))) "escape-nil")
    (is (= :done (do (dotimes [_ 50] (with-local-vars [x 1] (var-set x 2))) :done)) "loop-clean")))

(deftest p15-set-bang
  (testing "phase15_set_bang"
    (is (= 99 (ev "(def ^:dynamic *x* 1) (binding [*x* 10] (set! *x* 99) *x*)")) "bind-set")
    (is (= 5 (ev "(def ^:dynamic *x* 1) (binding [*x* 0] (set! *x* 5))")) "set-ret")
    (is (= 1 (ev "(def ^:dynamic *x* 1) (do (binding [*x* 0] (set! *x* 5)) *x*)")) "frame-only")
    (is (thrown-with-msg? Throwable #"Can't set! var that is not thread-bound: p15\.scratch\d+/\*x\*"
          (ev "(def ^:dynamic *x* 1) (set! *x* 8)")) "unbound-errs")
    (let [old *warn-on-reflection*]
      (try (is (true? (ev "(set! *warn-on-reflection* true)")) "warn-refl")
           (finally (set! *warn-on-reflection* old))))
    (is (= 9 (ev "(do (def ^:dynamic zz 0) (binding [zz 1] (set! zz 9)))")) "same-unit")
    (is (thrown-with-msg? Throwable #"Can't set! var that is not thread-bound: p15\.scratch\d+/y"
          (ev "(def y 1) (set! y 2)")) "not-dyn")
    (is (thrown-with-msg? Throwable #"set! expects 2 args, got 1"
          (ev "(set! *warn-on-reflection*)")) "arity")))

(deftest p15-ns-binding-roundtrip
  (testing "phase15_ns_binding_roundtrip"
    (let [[inside after before]
          (ev "(def b (ns-name *ns*)) (def inside (binding [*ns* *ns*] (in-ns (quote p15.tmp.x)) (ns-name *ns*))) [inside (ns-name *ns*) b]")]
      (is (= 'p15.tmp.x inside) "inside-and-restore")
      (is (= before after) "inside-and-restore: restored"))
    (is (= 42 (ev "(binding [*ns* *ns*] (in-ns (quote p15.tmp.y))) (inc 41)")) "core-resolves-after")
    (is (re-find #"^p15\.scratch" (str (ev "(binding [*ns* *ns*] (in-ns (quote p15.a)) (binding [*ns* *ns*] (in-ns (quote p15.b)))) (ns-name *ns*)")))
        "nested-roundtrip")))

(deftest p15-ns-runtime-fns
  (testing "phase15_ns_runtime_fns"
    (is (= [42 true]
           (ev "(def outer (ns-name *ns*)) (def n (binding [*ns* *ns*] (in-ns (gensym)) (apply clojure.core/use [(quote clojure.core)]) (inc 41))) [n (= outer (ns-name *ns*))]"))
        "temp-ns-shape")
    (is (= 'p15.some.tmp (binding [*ns* *ns*] (ns-name (in-ns 'p15.some.tmp)))) "in-ns-returns-ns")
    (is (= 'p15.t2 (binding [*ns* *ns*] (ns-name (apply in-ns ['p15.t2])))) "apply-in-ns")))

(deftest p15-namespace-values
  ;; AD-010 pin: a Namespace prints as #object[Namespace "name"].
  (testing "phase15_namespace"
    (let [u (the-ns 'user)]
      (is (= 'user (ns-name u)) "ns-name")
      (is (= "user" (str u)) "str-ns")
      (is (= "#object[Namespace \"user\"]" (pr-str u)) "pr-ns")
      (is (= u (the-ns 'user)) "identity"))
    (is (nil? (find-ns 'p15-nope)) "find-miss")
    (is (= 'p15.my.app (ns-name (create-ns 'p15.my.app))) "create")
    (is (= "#object[Namespace \"p15.foo.bar\"]"
           (pr-str (ev "(do (in-ns (quote p15.foo.bar)) clojure.core/*ns*)"))) "in-ns")
    (is (= #'clojure.core/map (ns-resolve 'clojure.core 'map)) "resolve")
    (is (true? (ev "(do (def zzz 7) (contains? (ns-interns *ns*) (quote zzz)))")) "interns")
    (is (contains? (ns-publics (the-ns 'clojure.core)) 'reduce) "core-pub-builtin")
    (is (contains? (ns-map (the-ns 'clojure.core)) 'reduce) "core-map-builtin"))
  (testing "AD-053 kernel-helper namespace"
    (is (some? (find-ns 'cljw.internal)) "ad053-internal-ns")
    (is (nil? (find-ns 'rt)) "ad053-rt-gone")
    (is (not (contains? (ns-publics (the-ns 'clojure.core)) '__class)) "ad053-no-leak"))
  (testing "intern"
    (is (= 42 (deref (intern (create-ns 'p15.foo.iv) 'x 42))) "intern-3ary")
    (is (= "#'p15.foo.iv5/q" (pr-str (intern (create-ns 'p15.foo.iv5) 'q 1))) "intern-ret")
    (is (= 5 (do (intern (create-ns 'p15.foo.iv6) 'k 5) (deref (intern (the-ns 'p15.foo.iv6) 'k)))) "intern-2ary-keeps")
    (is (= "#'p15.foo.iv4/w" (pr-str (do (intern (create-ns 'p15.foo.iv4) 'w) (find-var 'p15.foo.iv4/w)))) "intern-2ary-var")))

(deftest p15-ns-docstring
  (testing "phase15_ns_docstring"
    (is (= ["p15.foo.bar2" 42] (ev "(ns p15.foo.bar2 \"my docstring\" (:refer-clojure)) [(name (ns-name *ns*)) (inc 41)]")) "ns-docstring")
    (is (= ["p15.baz" 2] (ev "(ns p15.baz \"doc\" {:author \"x\"} (:refer-clojure)) [(name (ns-name *ns*)) (inc 1)]")) "ns-docstring-attrmap")
    (is (= "p15.plain" (ev "(ns p15.plain (:refer-clojure)) (name (ns-name *ns*))")) "ns-no-docstring")
    (ev "(ns p15.dm.doc \"the doc\")")
    (is (= "the doc" (:doc (meta (find-ns 'p15.dm.doc)))) "ns-doc-meta")
    (let [n (create-ns 'p15.dm.alter)]
      (alter-meta! n assoc :k 1)
      (is (= [1 nil] [(:k (meta n)) (do (reset-meta! n nil) (meta n))]) "ns-alter-meta"))
    (ev "(ns p15.dm.attr \"d\" {:author \"a\" :added \"1.0\"})")
    (is (= ["d" "a" "1.0"] ((juxt :doc :author :added) (meta (find-ns 'p15.dm.attr)))) "ns-attr-meta")
    (ev "(ns ^{:k 1} p15.dm.sym)")
    (is (= 1 (:k (meta (find-ns 'p15.dm.sym)))) "ns-name-sym-meta")))

(deftest p15-campaign-keywords
  (testing "phase15_campaign_keywords: Namespace interop"
    (is (symbol? (.name *ns*)) "ns-dot-name")
    (is (= "user" (str (.getName (the-ns 'user)))) "ns-dot-getname")
    (is (= "user" (.toString (the-ns 'user))) "ns-dot-str")))

(deftest p15-use-refer-all
  (testing "phase15_use_refer_all"
    (is (= "HI" (ev "(require (quote [clojure.string :refer :all])) (upper-case \"hi\")")) "refer-all")
    (is (= "HI" (ev "(ns p15.use1 (:use clojure.string)) (upper-case \"hi\")")) "use-string")
    (is (= [2 0] (binding [clojure.test/*test-out* (java.io.StringWriter.)
                           clojure.test/*report-counters* nil
                           clojure.test/*testing-vars* (list)
                           clojure.test/*testing-contexts* (list)]
                   (ev "(ns p15.use2 (:use clojure.test)) (deftest t (is (= 1 1)) (is (= 2 2))) (let [s (run-tests)] [(:pass s) (:fail s)])")))
        "use-test")
    (load-file "test/e2e/fixtures/cljwlib/demo/math.clj")
    (is (= 36 (ev "(ns p15.use3 (:use demo.math)) (square 6)")) "use-disk")
    (is (= ["X" #{1 2}] (ev "(ns p15.use4 (:use clojure.string clojure.set)) [(upper-case \"x\") (union #{1} #{2})]")) "use-multi")))

(deftest p15-use-libspec-filter
  (testing "phase15_use_libspec_filter"
    (is (= #{1 2} (ev "(ns p15.lf1 (:use [clojure.set :only (union)])) (union #{1} #{2})")) "only-refers")
    (is (nil? (ev "(ns p15.lf2 (:use [clojure.set :only (union)])) (resolve (quote intersection))")) "only-excludes")
    (is (= #{1 3} (ev "(ns p15.lf3 (:use [clojure.set :only [union]])) (union #{1} #{3})")) "only-vector")
    (is (= #{1 2} (ev "(ns p15.lf4 (:use [clojure.set :exclude (intersection difference)])) (union #{1} #{2})")) "excl-refers")
    (is (nil? (ev "(ns p15.lf5 (:use [clojure.set :exclude (intersection)])) (resolve (quote intersection))")) "excl-blocks")
    (is (= "HI" (ev "(require (quote [clojure.string :only (upper-case)])) (upper-case \"hi\")")) "req-only")))

(deftest p15-require-runtime-fn
  (testing "phase15_require_runtime_fn"
    (is (= "HI" (ev "(let [n (quote clojure.string)] (require n)) (clojure.string/upper-case \"hi\")")) "require-computed")
    (is (= #{1 2} (ev "(apply require [(quote clojure.set)]) (clojure.set/union #{1} #{2})")) "apply-require")
    (is (= "ab" (ev "(let [s (quote [clojure.string :as cs])] (require s)) (cs/lower-case \"AB\")")) "require-as-alias")
    (is (= "OK" (ev "(require '[clojure.string :as s]) (s/upper-case \"ok\")")) "literal-still")
    (is (thrown-with-msg? Throwable #"Could not locate" (require 'p15.no.such.lib)) "missing-lib (from phase15_require_fs)")))

(deftest p15-ns-import
  (testing "phase15_ns_import"
    (is (true? (ev "(ns p15.im1 (:import java.util.UUID)) (uuid? (UUID/randomUUID))")) "sym-form")
    (is (true? (ev "(ns p15.im2 (:import [java.util UUID])) (uuid? (UUID/randomUUID))")) "prefix-form")
    (is (true? (ev "(ns p15.im3 (:import java.util.UUID)) (uuid? (java.util.UUID/randomUUID))")) "fqcn-still")
    (is (= 3 (ev "(ns p15.im4) (+ 1 2)")) "no-import")
    (is (= :loaded (ev "(ns p15.im5 (:import java.util.ServiceLoader)) :loaded")) "unsupp-load")
    (is (thrown-with-msg? Throwable #"Unable to resolve symbol: 'ServiceLoader'"
          (ev "(ns p15.im6 (:import java.util.ServiceLoader)) (ServiceLoader.)")) "unsupp-use")))

(deftest p15-import-macro
  (testing "phase15_import_macro"
    (is (= 42 (ev "(import (quote (java.lang Integer))) (Integer/parseInt \"42\")")) "prefix-list")
    (is (= 7 (ev "(import (quote java.lang.Long)) (Long/parseLong \"7\")")) "bare-symbol")
    (is (= [3 4] (ev "(import (quote (java.lang Integer Long))) [(Integer/parseInt \"3\") (Long/parseLong \"4\")]")) "multi-class")
    (is (= '(do (import* "java.lang.Boolean") (import* "java.lang.Integer"))
           (macroexpand-1 '(import (quote (java.lang Boolean Integer))))) "expands-to-import-star")
    (is (= [5 6] (ev "(import (quote [java.lang Integer Long])) [(Integer/parseInt \"5\") (Long/parseLong \"6\")]")) "prefix-vector")))

(deftest p15-aliased-macro
  ;; The script built a disk lib off deps.edn :paths; the analyzer path under
  ;; test (alias-translate a qualified macro head) is the same for an ns that
  ;; already exists in the image.
  (testing "phase15_aliased_macro"
    (ev "(ns p15.mlib.core) (defmacro pick [sym] (list (quote quote) sym))")
    (is (= 'wildname (ev "(require '[p15.mlib.core :as m]) (m/pick wildname)")) "aliased_macro_expands")
    (is (= 'wildname (ev "(require 'p15.mlib.core) (p15.mlib.core/pick wildname)")) "qualified_macro_expands")))
