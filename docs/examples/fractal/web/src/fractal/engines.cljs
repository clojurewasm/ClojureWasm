(ns fractal.engines
  "Render engines. Every engine answers render-on with a promise of
  {:pixels Uint8ClampedArray(w*h*4 RGBA) :ms render-ms :iters total}.

  browser-<kernel>  that kernel's .wasm instantiated in this tab
  browser-js        the same pixel math in plain JavaScript, no wasm
  server-<engine>   native cljw renders (zwasm jit/interp, or cljw-raster)")

(defonce kernels (atom {}))

(def raster-url
  "The raster engine's tile server (replikativ/raster on the JVM, ../raster).
  Default: port 8081 on this host; ?raster=<url> overrides."
  (or (.get (js/URLSearchParams. js/location.search) "raster")
      (str js/location.protocol "//" js/location.hostname ":8081")))

(defn- probe-raster
  "Resolves to [\"raster-jvm\"] when the raster server answers, else []."
  []
  (let [ctl (js/AbortController.)]
    (js/setTimeout #(.abort ctl) 1500)
    (-> (js/fetch (str raster-url "/engines") #js {:signal (.-signal ctl)})
        (.then #(if (.-ok %) ["raster-jvm"] []))
        (.catch (constantly [])))))

(defn- fetch-json [url]
  (-> (js/fetch url) (.then #(.json %))))

(defn load!
  "Fetch the server's engine list and instantiate every kernel this browser
  validates. Resolves to {:server [...] :kernels [...]}."
  []
  (-> (fetch-json "/engines")
      (.catch (fn [_] #js {:engines #js [] :kernels #js ["zig"]}))
      (.then
       (fn [^js data]
         (let [server (vec (.-engines data))
               ids (vec (.-kernels data))]
           (-> (js/Promise.all
                (clj->js
                 (for [k ids]
                   (-> (js/fetch (str "/kernel.wasm?k=" k))
                       (.then #(.arrayBuffer %))
                       (.then (fn [bytes]
                                (when (js/WebAssembly.validate bytes)
                                  (.then (js/WebAssembly.instantiate bytes #js {})
                                         #(swap! kernels assoc k (.. % -instance -exports))))))
                       (.catch #(js/console.warn "kernel" k %))))))
               (.then (fn [_] (probe-raster)))
               (.then (fn [raster] {:server server :raster raster :kernels (filterv @kernels ids)}))))))))

(defn names
  "Engine names in display order."
  [{:keys [server kernels raster]}]
  (vec (concat (map #(str "browser-" %) kernels) ["browser-js"] (map #(str "server-" %) server) raster)))

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

(defn- now [] (js/performance.now))

(defn render-on
  "Render one w x h tile of view (cx, cy, scale) on engine. Server ms is the
  guest render time from X-Render-Ms, so network time is excluded."
  [engine {:keys [cx cy scale w h]} iter]
  (cond
    (= engine "browser-js")
    (let [t0 (now) r (js-raster cx cy scale w h iter)]
      (js/Promise.resolve (assoc r :ms (- (now) t0))))

    (.startsWith engine "browser-")
    (let [k (subs engine 8)
          ^js ex (get @kernels k)
          f (if (= k "zig-simd") (.-render_simd ex) (.-render ex))
          t0 (now)
          _ (.set_view ex cx cy scale)
          iters (js/Number (f w h iter))
          ms (- (now) t0)]
      (js/Promise.resolve
       {:pixels (js/Uint8ClampedArray. (.. ex -memory -buffer) (.fb_ptr ex) (* w h 4))
        :ms ms :iters iters}))

    :else
    (let [q (js/URLSearchParams. #js {:cx cx :cy cy :scale scale :w w :h h :iter iter
                                      :engine (if (= engine "raster-jvm") engine (subs engine 7))})
          base (if (= engine "raster-jvm") raster-url "")
          t0 (now)]
      (-> (js/fetch (str base "/tile?" q))
          (.then (fn [^js resp]
                   (if (.-ok resp)
                     (.then (.arrayBuffer resp)
                            (fn [buf]
                              (let [total (- (now) t0)
                                    rms (js/parseFloat (or (.get (.-headers resp) "X-Render-Ms") "NaN"))]
                                {:pixels (js/Uint8ClampedArray. buf)
                                 :ms (if (js/Number.isFinite rms) rms total)
                                 :iters (js/Number (or (.get (.-headers resp) "X-Iters") "0"))})))
                     (.then (.text resp) #(throw (js/Error. (str "tile: HTTP " (.-status resp) " " %)))))))))))

(defn checksum
  "The bench's framebuffer checksum, identical to bench.clj's."
  [px]
  (let [n (.-length px)]
    (loop [i 0 c 1]
      (if (< i n) (recur (inc i) (mod (+ (* c 31) (aget px i)) 2147483647)) c))))
