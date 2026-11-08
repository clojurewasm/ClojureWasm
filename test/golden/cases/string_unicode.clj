;; Multibyte handling: a runtime that counts bytes instead of characters looks
;; correct until the first non-ASCII input.
(def s "héllo, 世界 🌍")
(prn (count s) (subs s 0 5) (clojure.string/reverse "abc"))
(prn (seq "é世") (map int (seq "é世")))
(prn (clojure.string/upper-case "straße") (clojure.string/capitalize "ábc"))
(prn (count "🌍") (str \a \newline \tab))
;; Escapes must survive a print/read round trip.
(prn "tab\there" "nl\nhere" "quote\"here" "backslash\\here")
(prn (pr-str "tab\there") (read-string (pr-str "tab\there")))
