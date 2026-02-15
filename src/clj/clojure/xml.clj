;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/xml.clj
;; Upstream lines: 151
;; CLJW markers: 7

(ns ^{:doc "XML reading/writing."
      :author "Rich Hickey"}
 clojure.xml
 ;; CLJW: require clojure.string for parser (upstream uses Java SAX)
  (:require [clojure.string]))

;; CLJW: defstruct not implemented, use keyword accessors on plain maps
(def tag
  "Access :tag of an element"
  :tag)

(def attrs
  "Access :attrs of an element"
  :attrs)

(def content
  "Access :content of an element"
  :content)

;; --- Pure Clojure XML parser (CLJW: replaces SAX-based parser) ---

(defn- whitespace? [c]
  (or (= c \space) (= c \tab) (= c \newline) (= c \return)))

(defn- name-char? [c]
  (not (or (whitespace? c) (= c \>) (= c \/) (= c \=) (= c \<))))

(defn- skip-ws [s pos]
  (let [len (count s)]
    (loop [i pos]
      (if (and (< i len) (whitespace? (nth s i)))
        (recur (inc i))
        i))))

(defn- read-name [s pos]
  (let [len (count s)]
    (loop [i pos]
      (if (and (< i len) (name-char? (nth s i)))
        (recur (inc i))
        [(subs s pos i) i]))))

(defn- decode-entity [entity]
  (case entity
    "amp" "&"
    "lt" "<"
    "gt" ">"
    "quot" "\""
    "apos" "'"
    (if (= (nth entity 0) \#)
      (let [code (if (= (nth entity 1) \x)
                   (Integer/parseInt (subs entity 2) 16)
                   (Integer/parseInt (subs entity 1)))]
        (str (char code)))
      (str "&" entity ";"))))

(defn- decode-entities [s]
  (if (nil? (clojure.string/index-of s "&"))
    s
    (let [sb (StringBuilder.)
          len (count s)]
      (loop [i 0]
        (if (>= i len)
          (str sb)
          (let [c (nth s i)]
            (if (= c \&)
              (let [semi (clojure.string/index-of s ";" i)]
                (if semi
                  (do (.append sb (decode-entity (subs s (inc i) semi)))
                      (recur (inc semi)))
                  (do (.append sb c)
                      (recur (inc i)))))
              (do (.append sb c)
                  (recur (inc i))))))))))

(defn- read-attr-value [s pos]
  (let [quote-char (nth s pos)
        end (clojure.string/index-of s (str quote-char) (inc pos))]
    [(decode-entities (subs s (inc pos) end)) (inc end)]))

(defn- read-attrs [s pos]
  (loop [i (skip-ws s pos) attrs nil]
    (let [c (nth s i)]
      (if (or (= c \>) (= c \/))
        [attrs i]
        (let [[attr-name i2] (read-name s i)
              i3 (skip-ws s i2)
              ;; skip '='
              i4 (skip-ws s (inc i3))
              [attr-val i5] (read-attr-value s i4)]
          (recur (skip-ws s i5)
                 (assoc (or attrs {})
                        (keyword attr-name) attr-val)))))))

(defn- skip-comment [s pos]
  ;; pos is after "<!--", find "-->"
  (let [end (clojure.string/index-of s "-->" pos)]
    (+ end 3)))

(defn- skip-processing-instruction [s pos]
  ;; pos is after "<?", find "?>"
  (let [end (clojure.string/index-of s "?>" pos)]
    (+ end 2)))

(defn- read-cdata [s pos]
  ;; pos is after "<![CDATA[", find "]]>"
  (let [end (clojure.string/index-of s "]]>" pos)]
    [(subs s pos end) (+ end 3)]))

(defn- parse-xml* [s pos]
  (let [len (count s)]
    (loop [i (skip-ws s pos) children []]
      (if (>= i len)
        [children i]
        (let [c (nth s i)]
          (if (= c \<)
            (let [next-c (nth s (inc i))]
              (cond
                ;; End tag: </name>
                (= next-c \/)
                [children i]

                ;; Comment: <!-- ... -->
                (and (= next-c \!)
                     (< (+ i 3) len)
                     (= (nth s (+ i 2)) \-)
                     (= (nth s (+ i 3)) \-))
                (recur (skip-comment s (+ i 4)) children)

                ;; CDATA: <![CDATA[ ... ]]>
                (and (= next-c \!)
                     (< (+ i 8) len)
                     (= (subs s (+ i 2) (+ i 9)) "[CDATA["))
                (let [[text ni] (read-cdata s (+ i 9))]
                  (recur ni (conj children text)))

                ;; DOCTYPE or other declarations: skip
                ;; DOCTYPE may contain internal subset: <!DOCTYPE foo [ ... ]>
                (= next-c \!)
                (let [bracket (clojure.string/index-of s "[" i)
                      gt (clojure.string/index-of s ">" i)
                      end (if (and bracket (< bracket gt))
                            ;; Has internal subset — find ]>
                            (+ (clojure.string/index-of s "]>" bracket) 2)
                            ;; Simple declaration
                            (inc gt))]
                  (recur end children))

                ;; Processing instruction: <? ... ?>
                (= next-c \?)
                (recur (skip-processing-instruction s (+ i 2)) children)

                ;; Start tag
                :else
                (let [[tag-name i2] (read-name s (inc i))
                      i3 (skip-ws s i2)
                      c3 (nth s i3)]
                  (if (or (= c3 \>) (= c3 \/))
                    ;; No attributes
                    (if (= c3 \/)
                      ;; Self-closing: <tag/>
                      (let [elem {:tag (keyword tag-name) :attrs nil :content nil}]
                        (recur (+ i3 2) (conj children elem)))
                      ;; Open tag: <tag>
                      (let [[child-content i4] (parse-xml* s (inc i3))
                            ;; skip </tag>
                            [_ i5] (read-name s (+ i4 2))
                            i6 (inc (skip-ws s i5))
                            elem {:tag (keyword tag-name)
                                  :attrs nil
                                  :content (when (seq child-content) child-content)}]
                        (recur i6 (conj children elem))))
                    ;; Has attributes
                    (let [[attr-map i4] (read-attrs s i3)
                          c4 (nth s i4)]
                      (if (= c4 \/)
                        ;; Self-closing with attrs: <tag attr="val"/>
                        (let [elem {:tag (keyword tag-name) :attrs attr-map :content nil}]
                          (recur (+ i4 2) (conj children elem)))
                        ;; Open tag with attrs: <tag attr="val">
                        (let [[child-content i5] (parse-xml* s (inc i4))
                              ;; skip </tag>
                              [_ i6] (read-name s (+ i5 2))
                              i7 (inc (skip-ws s i6))
                              elem {:tag (keyword tag-name)
                                    :attrs attr-map
                                    :content (when (seq child-content) child-content)}]
                          (recur i7 (conj children elem)))))))))
            ;; Text content
            (let [next-lt (or (clojure.string/index-of s "<" i) len)
                  text (decode-entities (subs s i next-lt))]
              (if (every? whitespace? text)
                (recur next-lt children)
                (recur next-lt (conj children text))))))))))

(defn- parse-xml-string
  "Parse an XML string into a tree of element maps."
  [s]
  (let [[children _] (parse-xml* s 0)]
    (first children)))

;; CLJW: parse reads from file (string path) or java.io.File, uses pure Clojure parser
(defn parse
  "Parses and loads the source s, which can be a File or String naming
  a file path. Returns a tree of the xml/element maps, which have
  the keys :tag, :attrs, and :content, and accessor fns tag, attrs,
  and content."
  {:added "1.0"}
  ([s] (parse s nil))
  ([s startparse]
    ;; CLJW: startparse parameter accepted for API compat but ignored
   (parse-xml-string (slurp (str s)))))

;; CLJW: parse-str added for convenience — parses XML from a string directly
(defn parse-str
  "Parses XML from a string. Returns a tree of element maps."
  {:added "1.0"}
  [s]
  (parse-xml-string s))

;; emit-element and emit are from upstream (pure Clojure, no changes needed)
(defn emit-element [e]
  (if (instance? String e)
    (println e)
    (do
      (print (str "<" (name (:tag e))))
      (when (:attrs e)
        (doseq [attr (:attrs e)]
          (print (str " " (name (key attr)) "='" (val attr) "'"))))
      (if (:content e)
        (do
          (println ">")
          (doseq [c (:content e)]
            (emit-element c))
          (println (str "</" (name (:tag e)) ">")))
        (println "/>")))))

(defn emit [x]
  (println "<?xml version='1.0' encoding='UTF-8'?>")
  (emit-element x))
