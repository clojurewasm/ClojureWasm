(ns fractal.core
  "Entry point: mounts the reagent root, wires the keyboard and the URL hash,
  and exposes window.fractalApi, the surface the hive-cljs scenarios drive.
  Not window.fractal: that global is the root of the fractal.* namespaces."
  (:require [reagent.dom.client :as rdc]
            [re-frame.core :as rf]
            [re-frame.db :as db]
            [fractal.engines :as engines]
            [fractal.events :as ev]
            [fractal.ui :as ui]
            [fractal.view :as view]))

(defonce ^:private root (atom nil))

(defn- on-key [e]
  (when-not (= "INPUT" (.. e -target -tagName))
    (let [[w h] (:canvas @db/app-db)
          step (/ w 10)
          [hx hy] (or @ev/hover [(/ w 2) (/ h 2)])
          handled (case (.-key e)
                    ("ArrowLeft" "a") [::ev/pan (- step) 0]
                    ("ArrowRight" "d") [::ev/pan step 0]
                    ("ArrowUp" "w") [::ev/pan 0 (- step)]
                    ("ArrowDown" "s") [::ev/pan 0 step]
                    ("+" "=") [::ev/zoom-center 1.5]
                    ("-" "_") [::ev/zoom-center (/ 1 1.5)]
                    "j" [::ev/julia-at hx hy]
                    nil)]
      (when handled
        (.preventDefault e)
        (rf/dispatch handled)))))

(defn- apply-hash! []
  (let [{v :view iter :iter f :fractal} (view/<-hash js/location.hash)]
    (rf/dispatch [::ev/set-fractal (or f view/default-fractal)])
    (rf/dispatch [::ev/set-view (cond-> v iter (assoc :iter iter))])))

(defn- test-surface []
  #js {:view (fn [] (clj->js (assoc (:view @db/app-db) :iter (:iter @db/app-db))))
       :engines (fn [] (clj->js (:engines @db/app-db)))
       :usable (fn [] (clj->js (ev/usable @db/app-db)))
       :fractal (fn [] (clj->js (:fractal @db/app-db)))
       :formulas (fn [] (clj->js (map :id (:catalog @db/app-db))))
       :ready (fn [] (boolean (:ready? @db/app-db)))
       :panes (fn [] (clj->js (:panes @db/app-db)))
       :setView (fn [v] (rf/dispatch-sync [::ev/set-view (js->clj v :keywordize-keys true)]))
       :setFormula (fn [id] (rf/dispatch-sync [::ev/set-formula id]))
       :zoomAt (fn [px py f] (rf/dispatch-sync [::ev/zoom-at px py f]))
       :pan (fn [dx dy] (rf/dispatch-sync [::ev/pan dx dy]))
       ;; formula, jr and ji are optional: absent, the tile is plain Mandelbrot.
       :render (fn [engine cx cy scale w h iter formula jr ji]
                 (.then (engines/render-on engine (cond-> {:cx cx :cy cy :scale scale :w w :h h}
                                                    formula (assoc :formula formula)
                                                    (some? jr) (assoc :julia [jr ji]))
                                           iter)
                        (fn [{:keys [ms iters pixels]}]
                          #js {:ms ms :iters iters :checksum (engines/checksum pixels)})))
       :bench (fn [opts]
                (let [o (js->clj (or opts #js {}) :keywordize-keys true)]
                  (.then (ev/run-bench! (assoc o :engines (or (:engines o) (:engines @db/app-db))))
                         clj->js)))})

(defn- r-root [] [ui/root])

(defn ^:dev/after-load reload []
  (rf/clear-subscription-cache!)
  (rdc/render @root (r-root)))

(defn init []
  (rf/dispatch-sync [::ev/init])
  (apply-hash!)
  (set! js/window.fractalApi (test-surface))
  (js/window.addEventListener "keydown" on-key)
  (js/window.addEventListener "hashchange" apply-hash!)
  (reset! root (rdc/create-root (js/document.getElementById "app")))
  (rdc/render @root (r-root))
  (-> (engines/load!)
      (.then #(rf/dispatch [::ev/engines-loaded %]))))
