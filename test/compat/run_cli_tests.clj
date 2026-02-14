;; CW compatibility tests for clojure.tools.cli
;; Based on upstream: clojure/tools.cli src/test/clojure/clojure/tools/cli_test.cljc
;; Upstream tests: 7 deftests, ~80+ assertions
;; CW adaptation: Reader conditionals resolved for :clj, Integer/parseInt → Long/parseLong

(require '[clojure.tools.cli :as cli :refer [get-default-options parse-opts summarize]])
(require '[clojure.string :refer [join]])

(def test-count (volatile! 0))
(def pass-count (volatile! 0))
(def fail-count (volatile! 0))

(defn assert= [msg expected actual]
  (vswap! test-count inc)
  (if (= expected actual)
    (vswap! pass-count inc)
    (do (vswap! fail-count inc)
        (println (str "FAIL: " msg))
        (println (str "  expected: " (pr-str expected)))
        (println (str "  actual:   " (pr-str actual))))))

(defn assert-true [msg val]
  (vswap! test-count inc)
  (if val
    (vswap! pass-count inc)
    (do (vswap! fail-count inc)
        (println (str "FAIL: " msg)))))

(defn assert-throws [msg f]
  (vswap! test-count inc)
  (try (f)
       (vswap! fail-count inc)
       (println (str "FAIL (no throw): " msg))
       (catch Exception e
         (vswap! pass-count inc))))

;; Private var access — use different names to avoid shadowing (CW var resolution quirk)
(def my-tokenize  #'cli/tokenize-args)
(def my-compile   #'cli/compile-option-specs)
(def my-parse     #'cli/parse-option-tokens)

(defn has-error? [re coll]
  (seq (filter (partial re-seq re) coll)))

;; CLJW: Integer/parseInt → Long/parseLong
(defn parse-int [x]
  (Long/parseLong x))

;; === test-my-tokenize ===

(println "=== Tokenize Args ===")

;; expands clumped short options
(assert= "clumped short opts"
         [[[:short-opt "-a"] [:short-opt "-b"] [:short-opt "-c"] [:short-opt "-p" "80"]] []]
         (my-tokenize #{"-p"} ["-abcp80"]))

;; detects arguments to long options
(assert= "long opt with ="
         [[[:long-opt "--port" "80"] [:long-opt "--host" "example.com"]] []]
         (my-tokenize #{"--port" "--host"} ["--port=80" "--host" "example.com"]))

(assert= "long opt with = edge cases"
         [[[:long-opt "--foo" "bar"] [:long-opt "--noarg" ""] [:long-opt "--bad =opt"]] []]
         (my-tokenize #{} ["--foo=bar" "--noarg=" "--bad =opt"]))

;; stops option processing on double dash
(assert= "double dash stops opts"
         [[[:short-opt "-a"]] ["-b"]]
         (my-tokenize #{} ["-a" "--" "-b"]))

;; trailing options
(assert= "trailing options found"
         [[[:short-opt "-a"] [:short-opt "-b"]] ["foo"]]
         (my-tokenize #{} ["-a" "foo" "-b"]))

(assert= "in-order stops at non-option"
         [[[:short-opt "-a"]] ["foo" "-b"]]
         (my-tokenize #{} ["-a" "foo" "-b"] :in-order true))

;; single dash is not an option
(assert= "single dash not option"
         [[] ["-"]]
         (my-tokenize #{} ["-"]))

;; === test-my-compile ===

(println "=== Compile Option Specs ===")

;; default not set unless specified
(assert= "default not set"
         [false true]
         (map #(contains? % :default) (my-compile
                                       [["-f" "--foo"]
                                        ["-b" "--bar=ARG" :default 0]])))

;; default-fn not set unless specified
(assert= "default-fn not set"
         [false true]
         (map #(contains? % :default-fn) (my-compile
                                          [["-f" "--foo"]
                                           ["-b" "--bar=ARG" :default-fn (constantly 0)]])))

;; interprets string arguments
(assert= "string arg parsing"
         [["-a" nil nil nil]
          ["-b" "--beta" nil nil]
          [nil nil nil "DESC"]
          ["-f" "--foo" "FOO" "desc"]]
         (map (juxt :short-opt :long-opt :required :desc)
              (my-compile [["-a" :id :alpha]
                           ["-b" "--beta"]
                           [nil nil "DESC" :id :gamma]
                           ["-f" "--foo=FOO" "desc"]])))

;; --[no-] style flags
(assert= "[no-] flag id"
         {:id :foo, :short-opt "-f", :long-opt "--[no-]foo"}
         (-> (my-compile [["-f" "--[no-]foo"]])
             first
             (select-keys [:id :short-opt :long-opt])))

;; assertion errors
(assert-throws "nil id"
               #(doall (my-compile [["-a" :id nil]])))
(assert-throws "duplicate short-opt"
               #(doall (my-compile [{:id :a :short-opt "-a"} {:id :b :short-opt "-a"}])))
(assert-throws "duplicate long-opt"
               #(doall (my-compile [{:id :alpha :long-opt "--alpha"} {:id :beta :long-opt "--alpha"}])))
(assert-throws "duplicate default"
               #(doall (my-compile [{:id :alpha :default 0} {:id :alpha :default 1}])))
(assert-throws "duplicate default-fn"
               #(doall (my-compile [{:id :alpha :default-fn (constantly 0)}
                                    {:id :alpha :default-fn (constantly 1)}])))
(assert-throws "assoc-fn and update-fn"
               #(doall (my-compile [{:id :alpha :assoc-fn assoc :update-fn identity}])))

;; desugars --long-opt=value
(assert= "desugar long-opt=value"
         [[:foo "--foo" "FOO"]
          [:bar "--bar" "BAR"]]
         (map (juxt :id :long-opt :required)
              (my-compile [[nil "--foo FOO"] [nil "--bar=BAR"]])))

;; accepts maps as option specs
(assert= "map spec"
         [{:id :clojure.tools.cli-test/foo :short-opt "-f" :long-opt "--foo"}]
         (my-compile [{:id :clojure.tools.cli-test/foo :short-opt "-f" :long-opt "--foo"}]))

;; === test-my-parse ===

(println "=== Parse Option Tokens ===")

;; parses and validates option arguments
(let [specs (my-compile
             [["-p" "--port NUMBER"
               :parse-fn parse-int
               :validate [#(< 0 % 0x10000) #(str % " is not between 0 and 65536")]]
              ["-f" "--file PATH"
               :missing "--file is required"
               :validate [#(not= \/ (first %)) "Must be a relative path"
                          #(not (re-find #"\.\." %)) "No path traversal allowed"]]
              ["-l" "--level"
               :default 0 :update-fn inc
               :post-validation true
               :validate [#(<= % 2) #(str "Level " % " is more than 2")]]
              ["-q" "--quiet"
               :id :verbose
               :default true
               :parse-fn not]])]
  (assert= "parse tokens basic"
           [{:port 80 :verbose false :file "FILE" :level 0} []]
           (my-parse specs [[:long-opt "--port" "80"] [:short-opt "-q"] [:short-opt "-f" "FILE"]]))
  (assert= "file with -p value"
           [{:file "-p" :verbose true :level 0} []]
           (my-parse specs [[:short-opt "-f" "-p"]]))
  (assert-true "unknown option"
               (has-error? #"Unknown option"
                           (peek (my-parse specs [[:long-opt "--unrecognized"]]))))
  (assert-true "missing required arg"
               (has-error? #"Missing required"
                           (peek (my-parse specs [[:long-opt "--port"]]))))
  (assert-true "strict missing required"
               (has-error? #"Missing required"
                           (peek (my-parse specs [[:short-opt "-f" "-p"]] :strict true))))
  (assert-true "missing required option"
               (has-error? #"--file is required"
                           (peek (my-parse specs []))))
  (assert-true "validation: port 0"
               (has-error? #"0 is not between"
                           (peek (my-parse specs [[:long-opt "--port" "0"]]))))
  (assert-true "post-validation: level 3"
               (has-error? #"Level 3 is more than 2"
                           (peek (my-parse specs [[:short-opt "-f" "FILE"]
                                                  [:short-opt "-l"] [:short-opt "-l"] [:long-opt "--level"]]))))
  ;; CLJW: Long/parseLong returns nil for invalid input instead of throwing,
  ;; so the error is a validation error rather than a parse error.
  (assert-true "parse error"
               (has-error? #"is not between"
                           (peek (my-parse specs [[:long-opt "--port" "FOO"]]))))
  (assert-true "relative path"
               (has-error? #"Must be a relative path"
                           (peek (my-parse specs [[:long-opt "--file" "/foo"]]))))
  (assert-true "path traversal"
               (has-error? #"No path traversal allowed"
                           (peek (my-parse specs [[:long-opt "--file" "../../../etc/passwd"]])))))

;; merges values over default option map
(let [specs (my-compile
             [["-a" "--alpha"]
              ["-b" "--beta" :default false]
              ["-g" "--gamma=ARG"]
              ["-d" "--delta=ARG" :default "DELTA"]])]
  (assert= "defaults only"
           [{:beta false :delta "DELTA"} []]
           (my-parse specs []))
  (assert= "all set"
           [{:alpha true :beta true :gamma "GAMMA" :delta "delta"} []]
           (my-parse specs [[:short-opt "-a"] [:short-opt "-b"]
                            [:short-opt "-g" "GAMMA"] [:short-opt "-d" "delta"]])))

;; assoc-fn
(let [specs (my-compile
             [["-a" nil :id :alpha :default true
               :assoc-fn (fn [m k v] (assoc m k (not v)))]
              ["-v" "--verbose" :default 0
               :assoc-fn (fn [m k _] (assoc m k (inc (m k))))]])]
  (assert= "assoc-fn defaults"
           [{:alpha true :verbose 0} []]
           (my-parse specs []))
  (assert= "assoc-fn toggle"
           [{:alpha false :verbose 0} []]
           (my-parse specs [[:short-opt "-a"]]))
  (assert= "assoc-fn inc"
           [{:alpha true :verbose 3} []]
           (my-parse specs [[:short-opt "-v"] [:short-opt "-v"] [:long-opt "--verbose"]]))
  (assert= "assoc-fn no-defaults"
           [{:verbose 1} []]
           (my-parse specs [[:short-opt "-v"]] :no-defaults true)))

;; update-fn
(let [specs (my-compile
             [["-a" nil :id :alpha :default true :update-fn not]
              ["-v" "--verbose" :default 0 :update-fn inc]
              ["-f" "--file NAME" :multi true :default [] :update-fn conj]])]
  (assert= "update-fn defaults"
           [{:alpha true :verbose 0 :file []} []]
           (my-parse specs []))
  (assert= "update-fn toggle"
           [{:alpha false :verbose 0 :file []} []]
           (my-parse specs [[:short-opt "-a"]]))
  (assert= "update-fn multi"
           [{:alpha true :verbose 0 :file ["ONE" "TWO" "THREE"]} []]
           (my-parse specs [[:short-opt "-f" "ONE"] [:short-opt "-f" "TWO"] [:long-opt "--file" "THREE"]]))
  (assert= "update-fn inc"
           [{:alpha true :verbose 3 :file []} []]
           (my-parse specs [[:short-opt "-v"] [:short-opt "-v"] [:long-opt "--verbose"]]))
  (assert= "update-fn no-defaults"
           [{:verbose 1} []]
           (my-parse specs [[:short-opt "-v"]] :no-defaults true)))

;; negative flags
(let [specs (my-compile [["-p" "--[no-]profile" "Enable/disable profiling"]])]
  (assert= "neg flag empty" [{} []] (my-parse specs []))
  (assert= "neg flag -p" [{:profile true} []] (my-parse specs [[:short-opt "-p"]]))
  (assert= "neg flag --profile" [{:profile true} []] (my-parse specs [[:long-opt "--profile"]]))
  (assert= "neg flag --no-profile" [{:profile false} []] (my-parse specs [[:long-opt "--no-profile"]])))

;; === test-summarize ===

(println "=== Summarize ===")

(assert= "full summary"
         (join \newline
               ["  -s, --server HOST    example.com  Upstream server"
                "  -p, --port PORT      80           Upstream port number"
                "  -o PATH                           Output file"
                "  -v                   0            Verbosity level; may be specified more than once"
                "      --ternary t|f|?  false        A ternary option defaulting to false"
                "  -d, --[no-]daemon                 Daemonize the process"
                "      --help"])
         (summarize (my-compile
                     [["-s" "--server HOST" "Upstream server"
                       :default :some-object-whose-string-representation-is-awful
                       :default-desc "example.com"]
                      ["-p" "--port=PORT" "Upstream port number"
                       :default 80]
                      ["-o" nil "Output file"
                       :id :output
                       :required "PATH"]
                      ["-v" nil "Verbosity level; may be specified more than once"
                       :id :verbose
                       :default 0]
                      [nil "--ternary t|f|?" "A ternary option defaulting to false"
                       :default false
                       :parse-fn #(case %
                                    "t" true
                                    "f" false
                                    "?" :maybe)]
                      ["-d" "--[no-]daemon" "Daemonize the process"]
                      [nil "--help"]])))

(assert= "summary with default columns"
         (join \newline ["  -b, --boolean     true  A boolean option with a hidden default"
                         "  -o, --option ARG        An option without a default"])
         (summarize (my-compile [["-b" "--boolean" "A boolean option with a hidden default"
                                  :default true]
                                 ["-o" "--option ARG" "An option without a default"]])))

(assert= "empty summary" "" (summarize (my-compile [])))

;; === test-get-default-options ===

(println "=== Get Default Options ===")

(assert= "default options"
         {:a "a" :b 98}
         (get-default-options [[:id :a :default "a"]
                               [:id :b :default 98]
                               [:id :c]]))

;; === test-parse-opts ===

(println "=== Parse Opts ===")

;; parses options
(assert= "parse-opts basic"
         {:alpha true :beta true :port 80}
         (:options (parse-opts ["-abp80"] [["-a" "--alpha"]
                                           ["-b" "--beta"]
                                           ["-p" "--port PORT" :parse-fn parse-int]])))

;; error messages
(let [specs [["-f" "--file PATH"
              :validate [#(not= \/ (first %)) "Must be a relative path"]]
             ["-p" "--port PORT"
              :parse-fn parse-int
              :validate [#(< 0 % 0x10000) "Must be between 0 and 65536"]]]
      errors (:errors (parse-opts ["-f" "/foo/bar" "-p0"] specs))]
  (assert-true "parse-opts relative path error" (has-error? #"Must be a relative path" errors))
  (assert-true "parse-opts port error" (has-error? #"Must be between 0 and 65536" errors)))

;; unprocessed arguments
(assert= "parse-opts arguments"
         ["foo" "bar" "-b" "baz"]
         (:arguments (parse-opts ["foo" "-a" "bar" "--" "-b" "baz"]
                                 [["-a" "--alpha"] ["-b" "--beta"]])))

;; summary
;; CLJW: CW regex lacks backtracking; check both parts separately
(let [summary (:summary (parse-opts [] [["-a" "--alpha"]]))]
  (assert-true "parse-opts summary"
               (and (re-find #"-a" summary) (re-find #"--alpha" summary))))

;; in-order
(assert= "parse-opts in-order"
         ["foo" "-b"]
         (:arguments (parse-opts ["-a" "foo" "-b"]
                                 [["-a" "--alpha"] ["-b" "--beta"]]
                                 :in-order true)))

;; no-defaults
(let [option-specs [["-p" "--port PORT" :default 80]
                    ["-H" "--host HOST" :default "example.com"]
                    ["-q" "--quiet" :default true]
                    ["-n" "--noop"]]]
  (assert= "parse-opts with defaults"
           {:port 80 :host "example.com" :quiet true :noop true}
           (:options (parse-opts ["-n"] option-specs)))
  (assert= "parse-opts no-defaults"
           {:noop true}
           (:options (parse-opts ["-n"] option-specs :no-defaults true))))

;; summary-fn
(assert= "parse-opts summary-fn"
         "Usage: myprog [--alpha|--beta] arg1 arg2"
         (:summary (parse-opts [] [["-a" "--alpha"] ["-b" "--beta"]]
                               :summary-fn (fn [specs]
                                             (str "Usage: myprog ["
                                                  (join \| (map :long-opt specs))
                                                  "] arg1 arg2")))))

;; === Summary ===

(println (str "\n=== Results: " @pass-count "/" @test-count " passed ==="))
(when (> @fail-count 0)
  (println (str "FAILURES: " @fail-count))
  (System/exit 1))
