;; The headline feature: a module compiled from another language, called like a
;; function. If this snapshot changes, the FFI's user-visible surface changed.
(def m (wasm/load "docs/examples/wasm/add.wasm"))
(prn (wasm/call m "add" 40 2))
(prn (wasm/call m "add" -1 1))
