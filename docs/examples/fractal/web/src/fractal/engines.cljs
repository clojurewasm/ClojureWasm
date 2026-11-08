(ns fractal.engines
  "Renderers for the page: an open set behind one port. Every renderer answers
  `render` with a promise of {:pixels Uint8ClampedArray(w*h*4) :ms :iters}.
    browser-<kernel>  that kernel's .wasm instantiated in this tab (WasmKernel)
    browser-js        the same pixel math in plain JavaScript (JsRaster)
    server-<engine>   cljw renders natively, zwasm or plain Clojure (RemoteTiles)
    <jvm engine>      the JVM server (jvm/): raster, CUDA (RemoteTiles)
  Discovery (Collect) fills `registry`; nothing parses an engine name.")

;; --- the port -----------------------------------------------------------------
(defprotocol IRenderer
  (id [r])
  (exact? [r] "True when held to golden.edn: fp64, kernel operation order. False for fp32.")
  (render [r tile iter] "Promise of {:pixels :ms :iters}; tile is {:cx :cy :scale :w :h}."))

(defn- now [] (js/performance.now))

;; --- adapters -----------------------------------------------------------------
(defrecord WasmKernel [rid ^js exports simd?]
  IRenderer
  (id [_] rid)
  (exact? [_] true)
  (render [_ {:keys [cx cy scale w h]} iter]
    (let [f (if simd? (.-render_simd exports) (.-render exports))
          t0 (now)
          _ (.set_view exports cx cy scale)
          iters (js/Number (f w h iter))
          ms (- (now) t0)]
      (js/Promise.resolve
       {:pixels (js/Uint8ClampedArray. (.. exports -memory -buffer) (.fb_ptr exports) (* w h 4))
        :ms ms :iters iters}))))

(defonce ^:private js-fb (atom (js/Uint8ClampedArray. 0)))

(defn- wave [phase c]
  (let [t (+ phase (/ c 3))]
    (js/Math.trunc (* 255 (- 1 (js/Math.abs (- (* 2 (- t (js/Math.floor t))) 1)))))))

(defn- color! [fb o n limit mag]
  (aset fb (+ o 3) 255)
  (if (== n limit)
    (do (aset fb o 0) (aset fb (+ o 1) 0) (aset fb (+ o 2) 0))
    (let [bounded (if (js/Number.isFinite mag) (max mag 4.000001) 1e300)
          phase (* 0.025 (- (+ n 1) (js/Math.log2 (* 0.5 (js/Math.log2 bounded)))))]
      (dotimes [c 3] (aset fb (+ o c) (wave phase c))))))

(defn js-raster
  "Plain-JS twin of the kernels' render. Returns {:pixels :iters}."
  [cx cy scale w h max-iter]
  (when (< (.-length @js-fb) (* w h 4))
    (reset! js-fb (js/Uint8ClampedArray. (* w h 4))))
  (let [fb @js-fb
        limit (min max-iter 67108863)
        hw (/ w 2)
        hh (/ h 2)
        total (volatile! 0)]
    (dotimes [y h]
      (let [ci (+ cy (* (- y hh) scale))]
        (dotimes [x w]
          (let [cr (+ cx (* (- x hw) scale))]
            (loop [n 0 zr 0.0 zi 0.0]
              (if (and (< n limit) (<= (+ (* zr zr) (* zi zi)) 4))
                (recur (inc n) (+ (- (* zr zr) (* zi zi)) cr) (+ (* (* 2 zr) zi) ci))
                (do (vswap! total + n)
                    (color! fb (* 4 (+ (* y w) x)) n limit (+ (* zr zr) (* zi zi))))))))))
    {:pixels (.subarray fb 0 (* w h 4)) :iters @total}))

(defrecord JsRaster []
  IRenderer
  (id [_] "browser-js")
  (exact? [_] true)
  (render [_ {:keys [cx cy scale w h]} iter]
    (let [t0 (now) r (js-raster cx cy scale w h iter)]
      (js/Promise.resolve (assoc r :ms (- (now) t0))))))

;; A tile server speaking the shared protocol: X-Render-Ms is the guest render
;; time, so network time is excluded from :ms.
(defrecord RemoteTiles [rid base engine exact]
  IRenderer
  (id [_] rid)
  (exact? [_] exact)
  (render [_ {:keys [cx cy scale w h]} iter]
    (let [q (js/URLSearchParams. #js {:cx cx :cy cy :scale scale :w w :h h :iter iter :engine engine})
          t0 (now)]
      (-> (js/fetch (str base "/tile?" q))
          (.then (fn [^js resp]
                   (if (.-ok resp)
                     (.then (.arrayBuffer resp)
                            (fn [buf]
                              (let [rms (js/parseFloat (or (.get (.-headers resp) "X-Render-Ms") "NaN"))]
                                {:pixels (js/Uint8ClampedArray. buf)
                                 :ms (if (js/Number.isFinite rms) rms (- (now) t0))
                                 :iters (js/Number (or (.get (.-headers resp) "X-Iters") "0"))})))
                     (.then (.text resp) #(throw (js/Error. (str "tile: HTTP " (.-status resp) " " %)))))))))))

;; --- Collect: discovery ----------------------------------------------------------
(def jvm-url
  "The JVM engines' server (jvm/, raster and CUDA). Default: port 8081 on this
  host; ?jvm=<url> overrides."
  (or (.get (js/URLSearchParams. js/location.search) "jvm")
      (str js/location.protocol "//" js/location.hostname ":8081")))

(defn- fetch-engines
  "Promise of the server at base's {:engines [...] :kernels [...]}, or empty
  when it does not answer within ms."
  [base ms]
  (let [ctl (js/AbortController.)]
    (js/setTimeout #(.abort ctl) ms)
    (-> (js/fetch (str base "/engines") #js {:signal (.-signal ctl)})
        (.then #(.json %))
        (.then (fn [^js d] {:engines (vec (.-engines d))
                            :kernels (vec (or (.-kernels d) #js []))
                            :inexact (set (or (.-inexact d) #js []))}))
        (.catch (constantly {:engines [] :kernels [] :inexact #{}})))))

(defn- wasm-kernel
  "Promise of a WasmKernel for kernel k, or nil when this browser cannot run it."
  [k]
  (-> (js/fetch (str "/kernel.wasm?k=" k))
      (.then #(.arrayBuffer %))
      (.then (fn [bytes]
               (when (js/WebAssembly.validate bytes)
                 (.then (js/WebAssembly.instantiate bytes #js {})
                        #(->WasmKernel (str "browser-" k) (.. % -instance -exports) (= k "zig-simd"))))))
      (.catch (fn [e] (js/console.warn "kernel" k e) nil))))

(defn discover
  "Promise of every renderer this page can reach, in display order."
  []
  (-> (js/Promise.all #js [(fetch-engines "" 5000) (fetch-engines jvm-url 1500)])
      (.then (fn [[cljw jvm]]
               (.then (js/Promise.all (clj->js (map wasm-kernel (:kernels cljw))))
                      (fn [kernels]
                        (vec (concat (remove nil? kernels)
                                     [(->JsRaster)]
                                     (for [e (:engines cljw)]
                                       (->RemoteTiles (str "server-" e) "" e (not ((:inexact cljw) e))))
                                     (for [e (:engines jvm)]
                                       (->RemoteTiles e jvm-url e (not ((:inexact jvm) e))))))))))))

;; --- the registry the page renders through ----------------------------------------
(defonce registry (atom (array-map)))

(defn load!
  "Discover and register every renderer; resolves to their ids in order."
  []
  (.then (discover)
         (fn [rs]
           (reset! registry (into (array-map) (map (juxt id identity)) rs))
           (mapv id rs))))

(defn names [ids] (vec ids))

(defn exact-engine? [engine] (boolean (some-> (get @registry engine) exact?)))

(defn render-on
  "Render a tile on the registered renderer named engine."
  [engine tile iter]
  (if-let [r (get @registry engine)]
    (render r tile iter)
    (js/Promise.reject (js/Error. (str "unknown engine " engine)))))

(defn checksum
  "The golden checksum, identical to golden.edn's."
  [px]
  (let [n (.-length px)]
    (loop [i 0 c 1]
      (if (< i n) (recur (inc i) (mod (+ (* c 31) (aget px i)) 2147483647)) c))))
