(ns fractal.ui
  "Reagent views. Pointer, wheel and resize input on the canvas dispatch
  re-frame events; nothing here touches the view state directly."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            [fractal.events :as ev]
            [fractal.view :as view]))

(def palette ["#58a6ff" "#3fb950" "#d29922" "#f78166" "#bc8cff" "#39c5cf"
              "#ff7b72" "#a5d6ff" "#7ee787" "#e3b341" "#ffa198" "#d2a8ff"])

(defn color-of [engines e]
  (nth palette (mod (max 0 (.indexOf (vec engines) e)) (count palette))))

(defn- swatch [engines e] [:span {:style {:color (color-of engines e)}} "▬ "])

(defn- fmt [n d] (.toFixed n d))

(defn- fmt-rate
  "Miter/s of iters over ms to d places, or - for a frame under the timer
  resolution."
  [iters ms d]
  (if-let [m (view/mits iters ms)] (fmt m d) "-"))

;; --- header -----------------------------------------------------------------------
(defn- engine-select
  "Every engine, the ones that cannot draw the current fractal disabled."
  [side]
  (let [engines @(rf/subscribe [:engines])
        ok? (set (ev/usable {:engines engines :caps @(rf/subscribe [:caps]) :fractal @(rf/subscribe [:fractal])}))
        cur @(rf/subscribe [side])]
    [:select {:id (if (= side :left) "engL" "engR") :value (or cur "")
              :on-change #(rf/dispatch [::ev/set-engine side (.. % -target -value)])}
     (for [e engines] ^{:key e} [:option {:value e :disabled (not (ok? e))} e])]))

(defn- fractal-controls
  "The formula on show and the seed: the c-plane set, or its Julia set."
  []
  (let [catalog @(rf/subscribe [:catalog])
        {:keys [formula julia]} @(rf/subscribe [:fractal])]
    [:div.ctl
     [:label "fractal "
      [:select {:id "formula" :value formula
                :on-change #(rf/dispatch [::ev/set-formula (.. % -target -value)])}
       (for [{:keys [id what]} catalog] ^{:key id} [:option {:value id :title what} (str id "  " what)])]]
     [:button {:id "julia" :class (when julia "active") :title "Julia set of this formula (j: k under the cursor)"
               :on-click #(rf/dispatch [::ev/toggle-julia])}
      (if julia (str "Julia k=" (.toPrecision (first julia) 4) (if (neg? (second julia)) "" "+")
                     (.toPrecision (second julia) 4) "i")
          "Julia")]]))

(defn- coord-inputs []
  (let [draft (r/atom {})]
    (fn []
      (let [v @(rf/subscribe [:view])
            shown #(get @draft % (if (= % :scale) (.toExponential (:scale v) 6) (.toPrecision (get v %) 15)))
            go! (fn []
                  (rf/dispatch [::ev/set-view (into {} (keep (fn [[k s]] (when-let [n (view/finite-num s)] [k n]))) @draft)])
                  (reset! draft {}))]
        [:div.ctl
         (for [[k label] [[:cx "x"] [:cy "y"] [:scale "scale"]]]
           ^{:key k}
           [:label label " "
            [:input {:id (name k) :type "text" :value (shown k)
                     :on-change #(swap! draft assoc k (.. % -target -value))
                     :on-key-down #(when (= "Enter" (.-key %)) (go!))}]])
         [:button {:id "go" :on-click go!} "Go"]]))))

(defn header []
  (let [iter @(rf/subscribe [:iter])
        split? @(rf/subscribe [:split?])
        tour? @(rf/subscribe [:tour?])]
    [:header
     [:h1 "fractal zoom"]
     [fractal-controls]
     [:div.ctl
      [:label "left " [engine-select :left]]
      [:label "right " [engine-select :right]]
      [:button {:id "split" :class (when split? "active") :on-click #(rf/dispatch [::ev/toggle-split])} "Split"]]
     [:div.ctl
      [:label "iter "
       [:input {:id "iter" :type "range" :min 32 :max 4096 :step 32 :value iter
                :on-change #(rf/dispatch [::ev/set-iter (js/Number (.. % -target -value))])}]
       [:span#iterval iter]]
      [:label "res "
       [:select {:id "res" :on-change #(rf/dispatch [::ev/set-res (js/Number (.. % -target -value))])}
        [:option {:value 1} "1"] [:option {:value 0.5} "1/2"] [:option {:value 0.25} "1/4"]]]]
     [:div.ctl
      [:button {:id "zin" :title "zoom in (+)" :on-click #(rf/dispatch [::ev/zoom-center 2])} "+"]
      [:button {:id "zout" :title "zoom out (-)" :on-click #(rf/dispatch [::ev/zoom-center 0.5])} "−"]
      [:button {:id "reset" :on-click #(rf/dispatch [::ev/reset])} "Reset"]
      [:button {:id "tour" :class (when tour? "active") :on-click #(rf/dispatch [::ev/toggle-tour])} "Tour"]
      [:button {:id "bench" :on-click #(rf/dispatch [::ev/bench])} "Bench"]]
     [coord-inputs]]))

;; --- the canvas -------------------------------------------------------------------
(defn- canvas-point [^js c e]
  (let [rect (.getBoundingClientRect c)]
    [(* (- (.-clientX e) (.-left rect)) (/ (.-width c) (.-width rect)))
     (* (- (.-clientY e) (.-top rect)) (/ (.-height c) (.-height rect)))]))

(defn- attach-input! [^js c]
  (let [pointers (atom {})]
    (.addEventListener c "wheel"
                       (fn [e] (.preventDefault e)
                         (let [[x y] (canvas-point c e)]
                           (rf/dispatch [::ev/zoom-at x y (js/Math.pow 1.0015 (- (.-deltaY e)))])))
                       #js {:passive false})
    (.addEventListener c "dblclick"
                       (fn [e] (.preventDefault e)
                         (let [[x y] (canvas-point c e)]
                           (rf/dispatch [::ev/zoom-at x y (if (.-shiftKey e) 0.5 2)]))))
    (.addEventListener c "pointerdown"
                       (fn [e] (try (.setPointerCapture c (.-pointerId e)) (catch :default _ nil))
                         (swap! pointers assoc (.-pointerId e) (canvas-point c e))
                         (rf/dispatch [::ev/stop-tour])))
    (.addEventListener c "pointermove"
                       (fn [e]
                         (reset! ev/hover (canvas-point c e))
                         (when-let [[px py] (get @pointers (.-pointerId e))]
                           (let [p (canvas-point c e)]
                             (if (= 2 (count @pointers))
                               (let [[a b] (vals @pointers)
                                     d0 (js/Math.hypot (- (first a) (first b)) (- (second a) (second b)))
                                     _ (swap! pointers assoc (.-pointerId e) p)
                                     [a' b'] (vals @pointers)
                                     d1 (js/Math.hypot (- (first a') (first b')) (- (second a') (second b')))]
                                 (when (pos? d0)
                                   (rf/dispatch [::ev/zoom-at (/ (+ (first a') (first b')) 2)
                                                 (/ (+ (second a') (second b')) 2) (/ d1 d0)])))
                               (do (swap! pointers assoc (.-pointerId e) p)
                                   (rf/dispatch [::ev/pan (- px (first p)) (- py (second p))])))))))
    (doseq [t ["pointerup" "pointercancel"]]
      (.addEventListener c t #(swap! pointers dissoc (.-pointerId %))))
    (let [fit! (fn []
                 (let [dpr (min (or js/window.devicePixelRatio 1) 2)
                       w (min 1024 (js/Math.floor (* dpr (.-clientWidth c))))
                       h (min 1024 (js/Math.floor (* dpr (.-clientHeight c))))]
                   (when (or (not= w (.-width c)) (not= h (.-height c)))
                     (set! (.-width c) w)
                     (set! (.-height c) h))
                   (rf/dispatch [::ev/canvas-size [w h]])))]
      (.observe (js/ResizeObserver. fit!) c)
      (fit!))))

(defn- hud-text [{:keys [engine ms iters w h error]} v iter {:keys [formula julia]}]
  (if error
    (str engine ": " error)
    (str engine "  " (fmt ms 1) " ms  " (fmt-rate iters ms 1) " Miter/s\n"
         formula (when julia (str " Julia k=" (.toPrecision (first julia) 6) "," (.toPrecision (second julia) 6))) "\n"
         "x " (.toPrecision (:cx v) 15) "\ny " (.toPrecision (:cy v) 15) "\n"
         "scale " (.toExponential (:scale v) 3) "  zoom " (.toExponential (view/zoom-level v) 2) "x\n"
         "iter " iter "  " w "x" h)))

(defn- mount-canvas! [c]
  (when (and c (not= c @ev/canvas-el))
    (reset! ev/canvas-el c)
    (attach-input! c)))

(defn stage []
  (r/create-class
   {:display-name "stage"
    :reagent-render
    (fn []
      (let [panes @(rf/subscribe [:panes])
            split? @(rf/subscribe [:split?])
            v @(rf/subscribe [:view])
            iter @(rf/subscribe [:iter])
            f @(rf/subscribe [:fractal])]
        [:div#wrap
         [:canvas#view {:ref mount-canvas!}]
         [:div#divider {:style {:display (if split? "block" "none")}}]
         [:div#hudL.hud (when-let [p (:L panes)] (hud-text p v iter f))]
         [:div#hudR.hud {:style {:display (if split? "block" "none")}}
          (when-let [p (:R panes)] (hud-text p v iter f))]]))}))

;; --- stats --------------------------------------------------------------------------
(defn- draw-chart! [^js c samples engines]
  (let [g (.getContext c "2d")
        w (.-width c) h (.-height c)
        max-ms (reduce max 1 (mapcat val samples))]
    (.clearRect g 0 0 w h)
    (doseq [[e s] samples :when (> (count s) 1)]
      (set! (.-strokeStyle g) (color-of engines e))
      (.beginPath g)
      (doseq [[i ms] (map-indexed vector s)]
        (let [x (* w (/ i 119)) y (- h 2 (* (- h 6) (/ ms max-ms)))]
          (if (zero? i) (.moveTo g x y) (.lineTo g x y))))
      (.stroke g))))

(defn chart []
  (let [el (atom nil)]
    (r/create-class
     {:display-name "chart"
      :component-did-update (fn [this] (let [[_ s e] (r/argv this)] (when @el (draw-chart! @el s e))))
      :reagent-render (fn [_samples _engines]
                        [:canvas#chart {:ref #(reset! el %) :width 600 :height 90}])})))

(defn live-stats []
  (let [engines @(rf/subscribe [:engines])
        totals @(rf/subscribe [:totals])
        samples @(rf/subscribe [:samples])]
    [:div
     [:table#live
      [:thead [:tr [:th "engine"] [:th "ms/frame"] [:th "Miter/s"] [:th "frames"]]]
      [:tbody
       (for [e engines :let [[ms iters frames] (get totals e)] :when frames]
         ^{:key e} [:tr [:td [swatch engines e] e] [:td (fmt (/ ms frames) 1)]
                    [:td (fmt-rate iters ms 2)] [:td frames]])]]
     [chart samples engines]
     [:p.note "Wheel or " [:kbd "+"] "/" [:kbd "-"] " zoom at the cursor, drag or arrows/" [:kbd "WASD"]
      " slide x and y, double-click zooms in (shift: out), two fingers pinch. " [:kbd "j"]
      " opens the Julia set of the point under the cursor. The URL hash keeps the view and the fractal."
      " Formulas other than Mandelbrot run on the engines whose caps list them (raster and CUDA on the JVM server)."]]))

(defn bench-table []
  (let [engines @(rf/subscribe [:engines])
        {:keys [w h views rows parity] :as bench} @(rf/subscribe [:bench])]
    [:div.scroll
     [:div#benchmeta.note
      (if-not bench
        "Bench renders a fixed view list on every engine that renders it: ms, Miter/s, iteration total (must match) and checksum."
        (str w "x" h " per cell. Server ms = guest render only. Green = iteration total and checksum equal the first engine's. n/a = the engine does not render that fractal."
             (case parity nil " Running..." true " Parity: all engines agree." " Parity: MISMATCH.")))]
     (when bench
       [:table#benchtab
        [:thead [:tr [:th "engine"] (for [[n] views] ^{:key n} [:th n])]]
        [:tbody
         (for [e (:engines bench)]
           ^{:key e}
           [:tr [:td [swatch engines e] e]
            (for [[n] views
                  :let [r (first (filter #(and (= n (:view %)) (= e (:engine %))) rows))
                        ref (first (filter #(and (= n (:view %)) (not (:error %)) (not (:skipped %))) rows))]]
              ^{:key n}
              [:td (cond
                     (nil? r) "…"
                     (:skipped r) [:span.note "n/a"]
                     (:error r) [:span.bad {:title (:error r)} "error"]
                     :else [:span {:title (str "iters " (:iters r) " checksum " (:checksum r))}
                            (fmt (:ms r) 1) " ms "
                            [:span {:class (if (and (= (:iters ref) (:iters r)) (= (:checksum ref) (:checksum r))) "ok" "bad")}
                             (if (:mits r) (fmt (:mits r) 1) "-") " Mi/s"]])])])]])]))

(defn root []
  [:<>
   [header]
   [stage]
   [:div#stats [live-stats] [bench-table]]])
