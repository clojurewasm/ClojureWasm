;; A WASI command that never returns: the minimal slowloris of guest code.
;; Used to prove (wasm/run …) is fuel-metered by default (D-347).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (loop $forever
      (br $forever))))
