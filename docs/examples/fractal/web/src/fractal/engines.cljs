(ns fractal.engines
  "Renderers for the page: an open set behind one port. Every renderer answers
  `render` with a promise of {:pixels Uint8ClampedArray(w*h*4) :ms :iters}.
    browser-<kernel>  that kernel's .wasm instantiated in this tab (WasmKernel)
    browser-js        the same pixel math in plain JavaScript (JsRaster)
    server-<engine>   cljw renders natively, zwasm or plain Clojure (RemoteTiles)
    <jvm engine>      the JVM server (jvm/): raster, CUDA (RemoteTiles)
  Discovery (Collect) fills `registry`; nothing parses an engine name."
  (:require [fractal.view :as view]))

;; --- the port -----------------------------------------------------------------
(defprotocol IRenderer
  (id [r])
  (exact? [r] "True when held to golden.edn: fp64, kernel operation order. False for fp32.")
  (caps [r] "{:formulas #{id} :julia? bool}: the fractals r renders.")
  (render [r tile iter] "Promise of {:pixels :ms :iters}; tile is {:cx :cy :scale :w :h
                         :formula :julia}, the last two optional."))

(def mandelbrot-only
  "The caps of a renderer that names nothing more: Mandelbrot on the c-plane,
  the same default the JVM port applies."
  {:formulas #{"mandelbrot"} :julia? false})

(defn caps-render?
  "Whether caps cover fractal f ({:formula id :julia k-or-nil})."
  [{:keys [formulas julia?]} {:keys [formula julia]}]
  (and (contains? formulas (or formula "mandelbrot"))
       (or (nil? julia) (boolean julia?))))

(defn renders?
  "Whether r can render fractal f."
  [r f]
  (caps-render? (caps r) f))

(defn- now [] (js/performance.now))

;; --- adapters -----------------------------------------------------------------
(defrecord WasmKernel [rid ^js exports simd?]
  IRenderer
  (id [_] rid)
  (exact? [_] true)
  (caps [_] mandelbrot-only)
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
  (caps [_] mandelbrot-only)
  (render [_ {:keys [cx cy scale w h]} iter]
    (let [t0 (now) r (js-raster cx cy scale w h iter)]
      (js/Promise.resolve (assoc r :ms (- (now) t0))))))

;; A tile server speaking the shared protocol: X-Render-Ms is the guest render
;; time, so network time is excluded from :ms.
(defn tile-query
  "The /tile query of tile at iter on engine: the formula and k only when
  they differ from plain Mandelbrot, so a Mandelbrot-only server never sees
  a parameter it does not know."
  [{:keys [cx cy scale w h formula julia]} iter engine]
  (let [q (js/URLSearchParams. #js {:cx cx :cy cy :scale scale :w w :h h :iter iter :engine engine})]
    (when (and formula (not= formula "mandelbrot")) (.set q "formula" formula))
    (when-let [[kr ki] julia] (.set q "jr" kr) (.set q "ji" ki))
    q))

(defrecord RemoteTiles [rid base engine exact capabilities]
  IRenderer
  (id [_] rid)
  (exact? [_] exact)
  (caps [_] capabilities)
  (render [_ tile iter]
    (let [t0 (now)]
      (-> (js/fetch (str base "/tile?" (tile-query tile iter engine)))
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
(defn jvm-url
  "The JVM engines' server (jvm/, raster and CUDA). Default: port 8081 on this
  host; ?jvm=<url> overrides. A fn, so loading this namespace needs no page."
  []
  (or (.get (js/URLSearchParams. js/location.search) "jvm")
      (str js/location.protocol "//" js/location.hostname ":8081")))

(defn- caps-of
  "Promote a server's renders entry ({formulas: [...], julia: bool}) to caps;
  a server that sends none (the cljw server) is Mandelbrot only."
  [^js entry]
  (if entry
    {:formulas (set (.-formulas entry)) :julia? (boolean (.-julia entry))}
    mandelbrot-only))

(defn- fetch-engines
  "Promise of the server at base's {:engines :kernels :inexact :caps
  :formulas}, or empty when it does not answer within ms."
  [base ms]
  (let [ctl (js/AbortController.)]
    (js/setTimeout #(.abort ctl) ms)
    (-> (js/fetch (str base "/engines") #js {:signal (.-signal ctl)})
        (.then #(.json %))
        (.then (fn [^js d]
                 (let [renders (.-renders d)]
                   {:engines (vec (.-engines d))
                    :kernels (vec (or (.-kernels d) #js []))
                    :inexact (set (or (.-inexact d) #js []))
                    :caps (into {} (for [e (.-engines d)] [e (caps-of (some-> renders (aget e)))]))
                    :formulas (js->clj (or (.-formulas d) #js []) :keywordize-keys true)})))
        (.catch (constantly {:engines [] :kernels [] :inexact #{} :caps {} :formulas []})))))

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

(defn catalog
  "The formulas the page can offer: the built-in Mandelbrot, then each
  server's, first entry per id wins, in order."
  [& server-lists]
  (vals (reduce (fn [acc f] (if (contains? acc (:id f)) acc (assoc acc (:id f) f)))
                (array-map)
                (apply concat view/builtin-catalog server-lists))))

(defn discover
  "Promise of {:renderers [...] :catalog [...]}: every renderer this page can
  reach, in display order, and the formulas they can render between them."
  []
  (let [jvm-base (jvm-url)]
    (-> (js/Promise.all #js [(fetch-engines "" 5000) (fetch-engines jvm-base 1500)])
        (.then (fn [[cljw jvm]]
                 (.then (js/Promise.all (clj->js (map wasm-kernel (:kernels cljw))))
                        (fn [kernels]
                          {:renderers
                           (vec (concat (remove nil? kernels)
                                        [(->JsRaster)]
                                        (for [e (:engines cljw)]
                                          (->RemoteTiles (str "server-" e) "" e (not ((:inexact cljw) e))
                                                         (get-in cljw [:caps e] mandelbrot-only)))
                                        (for [e (:engines jvm)]
                                          (->RemoteTiles e jvm-base e (not ((:inexact jvm) e))
                                                         (get-in jvm [:caps e] mandelbrot-only)))))
                           :catalog (vec (catalog (:formulas cljw) (:formulas jvm)))})))))))

;; --- the registry the page renders through ----------------------------------------
(defonce registry (atom (array-map)))

(defn load!
  "Discover and register every renderer; resolves to {:ids [...] :caps {id
  caps} :catalog [...]}."
  []
  (.then (discover)
         (fn [{:keys [renderers catalog]}]
           (reset! registry (into (array-map) (map (juxt id identity)) renderers))
           {:ids (mapv id renderers)
            :caps (into {} (map (juxt id caps)) renderers)
            :catalog catalog})))

(defn names [ids] (vec ids))

(defn exact-engine? [engine] (boolean (some-> (get @registry engine) exact?)))

(defn render-on
  "Render a tile on the registered renderer named engine; rejects a tile
  whose fractal that renderer does not render."
  [engine tile iter]
  (let [r (get @registry engine)]
    (cond
      (nil? r) (js/Promise.reject (js/Error. (str "unknown engine " engine)))
      (not (renders? r tile)) (js/Promise.reject (js/Error. (str engine " does not render " (:formula tile)
                                                                (when (:julia tile) " (Julia)"))))
      :else (render r tile iter))))

(defn checksum
  "The golden checksum, identical to golden.edn's."
  [px]
  (let [n (.-length px)]
    (loop [i 0 c 1]
      (if (< i n) (recur (inc i) (mod (+ (* c 31) (aget px i)) 2147483647)) c))))
