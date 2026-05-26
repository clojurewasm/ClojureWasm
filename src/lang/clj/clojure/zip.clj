;; clojure.zip — Phase 7 §9.9 row 7.13 / D-080 / ADR-0043.
;;
;; Functional zipper over hierarchical data. cw v1 ports JVM
;; clojure.zip's public API but uses a `defrecord ZipLoc` carrier
;; rather than JVM's vector-with-metadata shape — see ADR-0043 for
;; the representation rationale. defrecord sidesteps the D-075
;; with-meta / IObj / IMeta hard dependency.
;;
;; Forward commitment: the defrecord shape is the **permanent
;; finished form** of cw v1's zipper. D-075 landing does NOT
;; trigger a JVM-faithful migration (per ADR-0043 amendment A).
;;
;; ## Cycle 1 — representation + ctors + 16 leaves (this commit)
;;
;; - `(defrecord ZipLoc ...)` + `->ZipLoc` factory.
;; - `zipper` / `vector-zip` / `seq-zip` / `xml-zip` constructors.
;; - `node` / `branch?` / `children` / `make-node` leaf accessors.
;; - `zip-loc?` / `seq-zip?` / `vector-zip?` / `xml-zip?` predicates.
;;
;; Cycles 2-4 land navigation / traversal / mutation.

(ns clojure.zip (:refer-clojure))

;; ZipLoc field layout (per ADR-0043 Decision section, expanded to
;; carry the zipper-type fns directly so the generic `(zipper)`
;; constructor works for user-defined tree shapes):
;;
;; - node         current node value.
;; - path         parent ZipLoc or nil at root.
;; - lefts        vector of sibling nodes to the left of `node`.
;; - rights       vector of sibling nodes to the right of `node`.
;; - end?         boolean — set by `(next loc)` once depth-first
;;                walk exhausts (cycle 3 wires this).
;; - branch-fn    predicate: is the current node a branch?
;; - children-fn  fn: branch node → seq of children.
;; - make-node-fn fn: (node, children-seq) → new branch node.
;; - kind         keyword `:zipper` / `:vector` / `:seq` / `:xml`
;;                — drives the source-shape predicates without
;;                comparing fn identity.
(defrecord ZipLoc [node path lefts rights end?
                   branch-fn children-fn make-node-fn kind])

;; ----------------------------------------------------------------
;; Constructors
;; ----------------------------------------------------------------

;; `(zipper branch? children make-node root)` — generic constructor.
;; Returns a fresh root ZipLoc. The 3 fns define the tree shape:
;; branch? recognises branch nodes; children returns a seq of a
;; branch's children; make-node rebuilds a branch given (node,
;; new-children-seq).
(defn zipper [b c m root]
  (->ZipLoc root nil [] [] false b c m :zipper))

;; `(vector-zip root)` — zipper over Clojure vectors (every vector
;; is a branch; children are its elements; rebuilding rewraps as
;; vector via `vec`).
(defn vector-zip [root]
  (->ZipLoc root nil [] [] false
            vector?
            (fn* [n] (seq n))
            (fn* [_node children] (into [] children))
            :vector))

;; `(seq-zip root)` — zipper over Clojure seqs (lists / cons /
;; lazy-seqs). Every seq is a branch; children pass through;
;; rebuilding is identity-on-children since children are already
;; a seq.
(defn seq-zip [root]
  (->ZipLoc root nil [] [] false
            seq?
            identity
            (fn* [_node children] children)
            :seq))

;; `(xml-zip root)` — zipper over Clojure XML element maps
;; (`{:tag :foo :attrs {} :content [...]}`-shaped). A node is a
;; branch when it is a map (= XML element); children come from
;; the `:content` key; rebuild keeps the rest of the map and
;; replaces `:content` with the new children vector.
;;
;; cw v1 uses `(get node :content)` rather than `(:content node)`
;; because D-085 keyword-as-fn callable is not yet landed
;; (ADR-0043 §Substrate verification). Once D-085 lands, the
;; `(get …)` calls can opportunistically flip to `(:content …)`
;; for ergonomic uniformity.
(defn xml-zip [root]
  (->ZipLoc root nil [] [] false
            (fn* [n] (map? n))
            (fn* [n] (get n :content))
            (fn* [n cs] (assoc n :content (into [] cs)))
            :xml))

;; ----------------------------------------------------------------
;; Leaf accessors — `node` / `branch?` / `children` / `make-node`
;; ----------------------------------------------------------------

(defn node [loc] (.node loc))

(defn branch? [loc] ((.branch-fn loc) (.node loc)))

(defn children [loc]
  (if (branch? loc)
    ((.children-fn loc) (.node loc))
    nil))

(defn make-node [loc nd cs] ((.make-node-fn loc) nd cs))

;; ----------------------------------------------------------------
;; Predicates
;; ----------------------------------------------------------------

(defn zip-loc?    [x] (instance? ZipLoc x))
;; The predicates use explicit `if` rather than `(and ...)` because
;; the bootstrap `and` macro (expandAnd) returns the FIRST falsy
;; operand's value rather than `false` per Clojure semantics, which
;; surfaces as a subtle bug when the false-arm caller compares to
;; the literal `false` Value. Explicit `if` is unambiguous + cheaper.
(defn vector-zip? [x]
  (if (instance? ZipLoc x) (identical? :vector (.kind x)) false))
(defn seq-zip? [x]
  (if (instance? ZipLoc x) (identical? :seq (.kind x)) false))
(defn xml-zip? [x]
  (if (instance? ZipLoc x) (identical? :xml (.kind x)) false))
