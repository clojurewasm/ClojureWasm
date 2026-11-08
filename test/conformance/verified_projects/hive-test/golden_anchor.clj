(ns golden-anchor
  "Anchor hive-test goldens to THIS fixture, on the JVM and on native cljw
   alike, and refuse to invent one that is missing.

   Two defects motivated this, both observed on a warm native session
   (CLJW-HIVE-GOLDEN-ROOT):

   1. ANCHORING. `hive-test.golden.root/ClasspathProjectRoot` finds a project
      root by asking `clojure.java.io/resource` for the test namespace's own
      source file and walking up to the nearest `deps.edn`. cljw's
      `io/resource` returns nil for EVERY name by design (D-359: there is no
      classpath resource loader), so `-root-for` yields nil, `root/anchor`
      passes the RELATIVE path straight through, and the golden resolves
      against the process working directory. Under `cljw -M:laws` launched
      from the fixture that happens to be right; under a warm session rooted
      at the repository it silently means `<repo>/lazy-seqable.edn`.

   2. AUTO-CAPTURE. `hive-test.golden/assert-golden` writes a snapshot and
      PASSES when none exists, which is the correct first-run behaviour for a
      golden you are authoring and the wrong one for a corpus that is already
      checked in. Combined with (1), a native run created an unreviewed
      baseline at the repository root and reported success. A first-run pass
      is then not evidence of anything.

   Both are fixed here rather than upstream, through the seams hive-test
   already publishes: `*project-root*` (a ProjectRoot strategy) and `*store*`
   (a GoldenStore port). No hive-test change and no publish is needed.

   ## Layering (Stratified Design + CPPB)

   Bottom is most-critical-to-test, so the bottom is where the decisions live:

     L0 calculations   ordering the candidates, walking a path's ancestors,
                       naming what is missing. No I/O, no ambient state, no
                       host types. Testable with plain strings.
     L1 ports          `Environment` and `Filesystem`, two narrow protocols
                       (ISP). The resolver programs to these, never to
                       `System` or `java.io.File` (DIP), so a test substitutes
                       an in-memory reading with no redef and no disk (LSP).
     L2 shell          performs the readings, then calls L0. The only layer
                       that touches the host.
     L3 boundary       the hive-test seams and the binding composition.

   The point of the split is that `candidate-order` is where the anchoring bug
   actually lived, and it is now a pure function of four strings.

   The anchor deliberately does NOT use `io/resource`. It reads
   `java.class.path`, which cljw fills from its resolved load paths, and
   `user.dir`, which cljw answers from `std.process.currentPath`. Both runtimes
   implement both."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [hive-test.golden :as golden]
            [hive-test.golden.root :as root]
            [hive-test.golden.store :as store]))

;; ---------------------------------------------------------------------------
;; L0 calculations. Pure: same inputs, same answer, no I/O.
;; ---------------------------------------------------------------------------

(def markers
  "Files that IDENTIFY this fixture directory, and nothing more.

   Deliberately just the two structural files. An earlier version also listed
   the reviewed goldens here, which conflated two faults: removing one golden
   made every candidate fail the marker test, so the run died with \"no
   candidate directory carries the fixture markers\", blaming the working
   directory when the real fault was one missing file in the right directory.
   Identity and corpus are separate checks now, so each failure names its own
   cause."
  ["laws.clj" "deps.edn"])

(def golden-files
  "The reviewed golden corpus that must already be present.

   Checked in and reviewed against Clojure 1.12.4, so an absent one is a
   missing fixture rather than a first run. `missing-names` reports them by
   name; `guarded-store` refuses to create them."
  ["lazy-seqable.edn" "subvec.edn" "split-lines.edn" "replace.edn"])

(def ^:private conventional-subpath
  "Where this fixture sits inside the repository, for the last-resort guess."
  "test/conformance/verified_projects/hive-test")

(defn split-classpath
  "`class-path` split on `separator`, blanks dropped. Pure."
  [class-path separator]
  (if (str/blank? class-path)
    []
    (->> (str/split class-path (re-pattern (java.util.regex.Pattern/quote separator)))
         (remove str/blank?)
         vec)))

(defn ancestor-paths
  "`path` and each of its ancestors, nearest first. Pure string arithmetic on
   a posix path, so it needs no filesystem to enumerate a walk-up."
  [path]
  (when-not (str/blank? path)
    (let [trimmed (if (and (> (count path) 1) (str/ends-with? path "/"))
                    (subs path 0 (dec (count path)))
                    path)]
      (loop [p trimmed, acc []]
        (let [acc (conj acc p)
              idx (str/last-index-of p "/")]
          (cond
            (nil? idx) acc
            (zero? idx) (conj acc "/")
            :else (recur (subs p 0 idx) acc)))))))

(defn candidate-order
  "Every place the fixture could be, in priority order, as raw path strings.

   Pure function of an environment READING (see `reading`), which is what
   makes the anchoring rule testable without a filesystem. Order is the rule:
   an explicit root wins, then the classpath (where a correctly launched run
   always finds it), then a walk up from the working directory (which is what
   rescues a warm session rooted at the repository), then the conventional
   location as a last guess."
  [{:keys [cwd class-path path-separator explicit-root]}]
  (let [cwd (or cwd ".")]
    (vec
     (concat
      (when-not (str/blank? explicit-root) [explicit-root])
      (split-classpath class-path (or path-separator ":"))
      (ancestor-paths cwd)
      [(str cwd "/" conventional-subpath)]))))

(defn missing-names
  "Names in `required` for which `present?` is falsey. Pure and higher-order:
   the caller supplies the predicate, so the corpus rule is exercised without
   touching disk."
  [present? required]
  (vec (remove present? required)))

;; ---------------------------------------------------------------------------
;; L1 ports. Two narrow protocols, so a consumer depends on the abstraction.
;; ---------------------------------------------------------------------------

(defprotocol Environment
  "Ambient process readings. Narrow on purpose: the resolver needs exactly
   these two, and nothing else about the host."
  (-property [this k] "System property `k`, or nil.")
  (-variable [this k] "Environment variable `k`, or nil."))

(defprotocol Filesystem
  "The three filesystem questions the anchor asks."
  (-absolute [this base path] "`path` made absolute and canonical against `base`.")
  (-directory? [this path] "True when `path` is an existing directory.")
  (-child-exists? [this dir name] "True when `dir` contains `name`."))

;; ---------------------------------------------------------------------------
;; L1 adapters. The only code that names `System` or `java.io.File`.
;; ---------------------------------------------------------------------------

(defn host-environment
  "Environment backed by the real process."
  []
  (reify Environment
    (-property [_ k] (System/getProperty k))
    (-variable [_ k] (System/getenv k))))

(defn host-filesystem
  "Filesystem backed by the real disk.

   `-absolute` needs `getCanonicalFile`, which cljw gained alongside this work:
   it published `getCanonicalPath` and `getAbsolutePath` but not their
   File-returning twins, so this call raised \"No implementation of method\"
   natively until `getCanonicalFile` / `getAbsoluteFile` were added to
   `src/runtime/java/io/File.zig`."
  []
  (reify Filesystem
    (-absolute [_ base path]
      (let [f (io/file path)]
        (.getPath (.getCanonicalFile (if (.isAbsolute f) f (io/file base path))))))
    (-directory? [_ path] (.isDirectory (io/file path)))
    (-child-exists? [_ dir name] (.exists (io/file dir name)))))

(defn memory-filesystem
  "Filesystem over a plain map of `dir -> #{child names}`.

   The reason the ports exist: the anchoring rule can be exercised against a
   made-up tree, with no disk and no redef, which is the CPPB test that a pure
   core is supposed to buy."
  [tree]
  (reify Filesystem
    (-absolute [_ base path]
      (if (str/starts-with? path "/") path (str base "/" path)))
    (-directory? [_ path] (contains? tree path))
    (-child-exists? [_ dir name] (contains? (get tree dir #{}) name))))

;; ---------------------------------------------------------------------------
;; L2 shell. Performs the readings, delegates every decision to L0.
;; ---------------------------------------------------------------------------

(defn reading
  "The environment reading `candidate-order` consumes. The effect; the policy
   is in L0."
  [env]
  {:cwd (or (-property env "user.dir") ".")
   :class-path (or (-property env "java.class.path") "")
   :path-separator (or (-property env "path.separator") ":")
   :explicit-root (-variable env "CLJW_GOLDEN_ROOT")})

(defn identifies-fixture?
  "True when `dir` is a directory holding every identity marker."
  [fs dir]
  (and (-directory? fs dir)
       (every? (fn [m] (-child-exists? fs dir m)) markers)))

(defn resolve-root
  "Absolute path of this fixture, as a string.

   Throws when no candidate identifies the fixture, listing what was searched.
   Failing here is the point: the alternative is anchoring at a directory with
   no corpus, where every golden reads as a first run."
  [fs env]
  (let [r (reading env)
        base (:cwd r)
        tried (mapv (fn [p] (-absolute fs base p)) (candidate-order r))]
    (or (first (filter (fn [d] (identifies-fixture? fs d)) tried))
        (throw (ex-info (str "golden-anchor: no candidate directory carries the fixture "
                             "markers " (pr-str markers) ". Set CLJW_GOLDEN_ROOT to the "
                             "absolute path of " conventional-subpath ", or run from it.")
                        {:markers markers
                         :reading r
                         :tried tried})))))

(defn missing-goldens
  "Reviewed goldens absent from `root`, by name."
  [fs root]
  (missing-names (fn [g] (-child-exists? fs root g)) golden-files))

(defn assert-corpus!
  "Throw unless every reviewed golden is present under `root`.

   Distinct from the anchoring failure on purpose: this one means you are in
   the RIGHT directory and a reviewed file is gone, so it names the files."
  [fs root]
  (let [absent (missing-goldens fs root)]
    (when (seq absent)
      (throw (ex-info (str "golden-anchor: the reviewed golden corpus is incomplete at "
                           root ". Missing: " (str/join ", " absent)
                           ". These are checked in, so an absent one is a missing fixture "
                           "rather than a first run. Restore it from git.")
                      {:root root :missing absent})))
    root))

;; ---------------------------------------------------------------------------
;; L3 boundary. The hive-test seams and the binding composition.
;; ---------------------------------------------------------------------------

(defn fixture-project-root
  "A ProjectRoot answering `root` for every namespace.

   Every law in this fixture anchors to the same directory, so the test
   namespace is not consulted. That is the whole difference from the classpath
   walk-up: it cannot return nil, so `root/anchor` can never fall back to a
   working-directory-relative path."
  [^String root]
  (let [dir (io/file root)]
    (reify root/ProjectRoot
      (-root-for [_ _test-ns] dir))))

(defn guarded-store
  "A GoldenStore that will not invent a golden.

   Reads and existence checks delegate untouched. A WRITE is refused unless
   UPDATE_GOLDEN=true, which turns `assert-golden`'s absent-golden branch from
   a silent capture into a loud failure naming the path it wanted to create. A
   permitted write is read back and compared, so a snapshot that does not
   survive its own round trip through EDN is reported at capture time rather
   than as a mismatch on some later run."
  [delegate update-allowed?]
  (reify store/GoldenStore
    (-read [_ path] (store/-read delegate path))
    (-exists? [_ path] (store/-exists? delegate path))
    (-write! [_ path value]
      (when-not update-allowed?
        (throw (ex-info (str "golden-anchor: refusing to write the golden at " path
                             ". It is absent, and this corpus is reviewed and checked in, "
                             "so an absent golden is a missing fixture rather than a first "
                             "run. Restore the file, or set UPDATE_GOLDEN=true to capture "
                             "deliberately and review the diff.")
                        {:path path :update-golden false})))
      (store/-write! delegate path value)
      (let [read-back (store/-read delegate path)]
        (when-not (= value read-back)
          (throw (ex-info (str "golden-anchor: the golden written at " path
                               " did not survive a read back, so it does not describe "
                               "the value it was captured from.")
                          {:path path})))
        read-back))))

(defn update-allowed?
  "True when UPDATE_GOLDEN=true, the same switch hive-test itself reads."
  ([] (update-allowed? (host-environment)))
  ([env] (= "true" (-variable env "UPDATE_GOLDEN"))))

(defn bindings-for
  "The `*project-root*` / `*store*` bindings anchoring goldens at `root`."
  [root env]
  {#'golden/*project-root* (fixture-project-root root)
   #'golden/*store* (guarded-store (store/file-store) (update-allowed? env))})

(defn install
  "Resolve the fixture, assert its corpus, and return the bindings for it.
   One call so a runner cannot anchor without also checking the corpus."
  ([] (install (host-filesystem) (host-environment)))
  ([fs env]
   (let [root (assert-corpus! fs (resolve-root fs env))]
     {:root root :bindings (bindings-for root env)})))

(defmacro with-anchored-goldens
  "Run `body` with goldens anchored at this fixture and auto-capture refused.

   Wrap the whole run, not one assertion: the bindings are dynamic and
   `clojure.test` calls the assertions itself."
  [& body]
  `(with-bindings (:bindings (install)) ~@body))

(defn report
  "What the anchor resolved to, for a runner to print."
  ([] (report (host-filesystem) (host-environment)))
  ([fs env]
   (let [root (resolve-root fs env)]
     {:root root
      :update-golden (update-allowed? env)
      :missing (missing-goldens fs root)})))
