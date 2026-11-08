(println "before")
(throw (ex-info "boom" {:code 42 :nested {:k [1 2]}}))
