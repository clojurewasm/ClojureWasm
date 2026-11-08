;; Character and string rendering: the readable char names, escape sequences,
;; and non-ASCII passthrough.
(prn \a \A \0 \space \newline \tab \return \backspace \formfeed)
(prn (seq "a\nb\tc"))
(prn "tab\there" "nl\nhere" "quote\"here" "back\\slash")
(prn "ünïcødé" "日本語")
(pr "a\nb") (println)
(prn (str \a \newline) (char 65) (char 955) (int \A))
