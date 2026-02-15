;; clojure.pprint — Pretty-printing for Clojure data structures.
;; UPSTREAM-DIFF: Simplified implementation. pprint is a Zig builtin.
;; print-table ported from upstream.

(ns clojure.pprint)

;; pprint is registered as a Zig builtin in registry.zig

(defmacro pp
  "A convenience macro that pretty prints the last thing output. This is
exactly equivalent to (pprint *1)."
  {:added "1.2"}
  [] `(pprint *1))

(defn set-pprint-dispatch
  "Set the pretty print dispatch function to a function matching (fn [obj] ...)
where obj is the object to pretty print. That function will be called with *out* set
to a pretty printing writer to which it should do its printing.

For example functions, see simple-dispatch and code-dispatch in
clojure.pprint.dispatch.clj."
  {:added "1.2"}
  [function]
  (let [old-meta (meta #'*print-pprint-dispatch*)]
    (alter-var-root #'*print-pprint-dispatch* (constantly function))
    (alter-meta! #'*print-pprint-dispatch* (constantly old-meta)))
  nil)

(defmacro with-pprint-dispatch
  "Execute body with the pretty print dispatch function bound to function."
  {:added "1.2"}
  [function & body]
  `(binding [*print-pprint-dispatch* ~function]
     ~@body))

(defn- check-enumerated-arg [arg choices]
  (if-not (choices arg)
    (throw
     (IllegalArgumentException.
      (str "Bad argument: " arg ". It must be one of " choices)))))

(defn pprint-tab
  "Tab at this point in the pretty printing stream. kind specifies whether the tab
is :line, :section, :line-relative, or :section-relative.

Colnum and colinc specify the target column and the increment to move the target
forward if the output is already past the original target.

This function is intended for use when writing custom dispatch functions.

Output is sent to *out* which must be a pretty printing writer.

THIS FUNCTION IS NOT YET IMPLEMENTED."
  {:added "1.2"}
  [kind colnum colinc]
  (check-enumerated-arg kind #{:line :section :line-relative :section-relative})
  (throw (UnsupportedOperationException. "pprint-tab is not yet implemented")))

(defn print-table
  "Prints a collection of maps in a textual table. Prints table headings
   ks, and then a line of output for each row, corresponding to the keys
   in ks. If ks are not specified, use the keys of the first item in rows."
  ([ks rows]
   (when (seq rows)
     (let [widths (map
                   (fn [k]
                     (apply max (count (str k)) (map #(count (str (get % k))) rows)))
                   ks)
           spacers (map #(apply str (repeat % "-")) widths)
           fmts (map #(str "%" % "s") widths)
           fmt-row (fn [leader divider trailer row]
                     (str leader
                          (apply str (interpose divider
                                                (for [[col fmt] (map vector (map #(get row %) ks) fmts)]
                                                  (format fmt (str col)))))
                          trailer))]
       (println)
       (println (fmt-row "| " " | " " |" (zipmap ks ks)))
       (println (fmt-row "|-" "-+-" "-|" (zipmap ks spacers)))
       (doseq [row rows]
         (println (fmt-row "| " " | " " |" row))))))
  ([rows] (print-table (keys (first rows)) rows)))
