;; ADR-0135 A2 — a BARE component name (`greet_component.wasm`, no `./` or `/`)
;; resolves against the CLASSPATH (`-cp` / CLJW_PATH / deps.edn `:paths`), mirroring
;; how a `.clj` lib resolves. Run with `-cp test/e2e/fixtures/wasm`; the component is
;; NOT next to this file's cwd, only on the classpath.
(ns wasm.classpath
  (:require ["greet_component.wasm" :as g]))
(println "classpath:" (g/greet "cp"))
