(ns fractal.events
  "re-frame state: events, effects and subscriptions. The canvas paint is an
  effect (:fractal/paint), latest-wins with one frame in flight per pane.
  The fractal on show ({:formula :julia}) is state like the view; which
  engines may draw it is derived from each engine's caps, never from its
  name."
  (:require [re-frame.core :as rf]
            [fractal.engines :as engines]
            [fractal.view :as view]))

(def initial-db
  {:view view/home :iter 256 :res 1 :split? false
   :fractal view/default-fractal :catalog view/builtin-catalog
   :engines [] :caps {} :left nil :right nil :canvas [0 0]
   :panes {} :totals {} :samples {}
   :bench nil :tour? false :ready? false})

;; --- which engines can draw the current fractal (pure) --------------------------
(defn usable
  "The engines of db that render its fractal, in display order."
  [{:keys [engines caps fractal]}]
  (filterv #(engines/caps-render? (get caps % engines/mandelbrot-only) fractal) engines))

(defn fit-engines
  "Keep left and right when they render the fractal; otherwise the first
  usable engine on the left and, on the right, a cljw server engine when one
  can (so a split compares two runtimes), else the next usable one."
  [db]
  (let [ok (usable db)
        ok? (set ok)
        left (if (ok? (:left db)) (:left db) (first ok))
        right-pick (or (first (filter #(and (.startsWith % "server-") (not= % left)) ok))
                       (first (remove #{left} ok))
                       left)]
    (cond-> (assoc db :left left)
      (not (ok? (:right db))) (assoc :right right-pick))))

(defn with-fractal
  "db showing fractal f, framed at its home view, engines refitted."
  [db f]
  (let [[w] (:canvas db)]
    (-> db
        (assoc :fractal f :view (view/home-of (:catalog db) f w) :tour? false)
        fit-engines)))

;; --- painting -------------------------------------------------------------------
(defonce canvas-el (atom nil))
(defonce hover (atom nil))
(defonce ^:private pane-state (atom {}))

(defn- blit! [pixels w h dx dw H]
  (when-let [c @canvas-el]
    (let [tmp (js/document.createElement "canvas")
          ctx (.getContext c "2d")]
      (set! (.-width tmp) w)
      (set! (.-height tmp) h)
      (.putImageData (.getContext tmp "2d") (js/ImageData. (js/Uint8ClampedArray. pixels) w h) 0 0)
      (set! (.-imageSmoothingEnabled ctx) false)
      (.drawImage ctx tmp 0 0 w h dx 0 dw H))))

(defn- paint-pane! [id job]
  (if (get-in @pane-state [id :busy?])
    (swap! pane-state assoc-in [id :pending] job)
    (let [{:keys [engine view canvas slice res iter fractal]} job
          [W H] canvas
          [dx dw] slice
          pv (view/pane-view view canvas slice res)]
      (swap! pane-state assoc id {:busy? true})
      (-> (engines/render-on engine (merge pv fractal) iter)
          (.then (fn [{:keys [pixels ms iters]}]
                   (blit! pixels (:w pv) (:h pv) dx dw H)
                   (rf/dispatch [::frame-done id {:engine engine :ms ms :iters iters :w (:w pv) :h (:h pv)}])))
          (.catch (fn [e] (rf/dispatch [::frame-error id engine (.-message e)])))
          (.finally (fn []
                      (let [pending (get-in @pane-state [id :pending])]
                        (swap! pane-state assoc id {:busy? false})
                        (when pending (paint-pane! id pending)))))))))

(rf/reg-fx
 :fractal/paint
 (fn [{:keys [view canvas split? left right res iter fractal]}]
   (let [[W H] canvas]
     (when (and (>= W 8) (>= H 8) left)
       (let [lw (if split? (js/Math.floor (/ W 2)) W)
             job {:view view :canvas canvas :res res :iter iter :fractal fractal}]
         (paint-pane! :L (assoc job :engine left :slice [0 lw]))
         (when (and split? right)
           (paint-pane! :R (assoc job :engine right :slice [lw (- W lw)]))))))))

(rf/reg-fx
 :fractal/hash
 (fn [[v iter f]] (js/history.replaceState nil "" (view/->hash v iter f))))

(defn- repaint [db]
  {:db db
   :fx [[:fractal/paint (select-keys db [:view :canvas :split? :left :right :res :iter :fractal])]
        [:fractal/hash [(:view db) (:iter db) (:fractal db)]]]})

;; --- events ----------------------------------------------------------------------
(rf/reg-event-db ::init (fn [_ _] initial-db))

(rf/reg-event-fx
 ::engines-loaded
 (fn [{:keys [db]} [_ {:keys [ids caps catalog]}]]
   (repaint (-> db
                (assoc :engines ids :caps caps :catalog catalog :ready? true)
                fit-engines))))

(rf/reg-event-fx ::canvas-size (fn [{:keys [db]} [_ wh]] (repaint (assoc db :canvas wh))))

(rf/reg-event-fx
 ::set-view
 (fn [{:keys [db]} [_ v]]
   (let [merged (merge (:view db) (select-keys v [:cx :cy :scale]))]
     (repaint (cond-> db
                (view/valid? merged) (assoc :view merged)
                (:iter v) (assoc :iter (max 1 (js/Math.round (:iter v)))))))))

;; A fractal named by the URL keeps the URL's view; picking one in the page
;; frames it at its home (::set-formula, ::toggle-julia).
(rf/reg-event-fx
 ::set-fractal
 (fn [{:keys [db]} [_ f]]
   (repaint (fit-engines (assoc db :fractal (merge view/default-fractal f))))))

(rf/reg-event-fx
 ::set-formula
 (fn [{:keys [db]} [_ id]]
   (repaint (with-fractal db {:formula id :julia nil}))))

(rf/reg-event-fx
 ::toggle-julia
 (fn [{:keys [db]} _]
   (let [{:keys [formula julia]} (:fractal db)
         k (:julia (first (filter #(= formula (:id %)) (:catalog db))))]
     (repaint (with-fractal db {:formula formula :julia (when-not julia (or k [0 0]))})))))

(rf/reg-event-fx
 ::julia-at
 (fn [{:keys [db]} [_ px py]]
   (if (:julia (:fractal db))
     {:db db}
     (let [k (view/plane-point (:view db) (:canvas db) [px py])]
       (repaint (with-fractal db (assoc (:fractal db) :julia k)))))))

(rf/reg-event-fx
 ::zoom-at
 (fn [{:keys [db]} [_ px py factor]]
   (repaint (update db :view view/zoom-at (:canvas db) [px py] factor))))

(rf/reg-event-fx
 ::zoom-center
 (fn [{:keys [db]} [_ factor]]
   (let [[w h] (:canvas db)]
     (repaint (update db :view view/zoom-at (:canvas db) [(/ w 2) (/ h 2)] factor)))))

(rf/reg-event-fx ::pan (fn [{:keys [db]} [_ dx dy]] (repaint (update db :view view/pan [dx dy]))))

(rf/reg-event-fx
 ::reset
 (fn [{:keys [db]} _]
   (repaint (assoc db :tour? false :view (if (= view/default-fractal (:fractal db))
                                           view/home
                                           (view/home-of (:catalog db) (:fractal db) (first (:canvas db))))))))

(rf/reg-event-fx ::set-iter (fn [{:keys [db]} [_ n]] (repaint (assoc db :iter n))))
(rf/reg-event-fx ::set-res (fn [{:keys [db]} [_ r]] (repaint (assoc db :res r))))
(rf/reg-event-fx ::toggle-split (fn [{:keys [db]} _] (repaint (update db :split? not))))
(rf/reg-event-fx ::set-engine (fn [{:keys [db]} [_ side e]] (repaint (assoc db side e))))

(rf/reg-event-db
 ::frame-done
 (fn [db [_ id {:keys [engine ms iters] :as frame}]]
   (-> db
       (assoc-in [:panes id] frame)
       (update-in [:totals engine] (fnil (fn [[t i f]] [(+ t ms) (+ i iters) (inc f)]) [0 0 0]))
       (update-in [:samples engine] #(vec (take-last 120 (conj (or % []) ms)))))))

(rf/reg-event-db
 ::frame-error
 (fn [db [_ id engine msg]] (assoc-in db [:panes id] {:engine engine :error msg})))

;; Tour: a timer drives ::tour-tick until the user stops it or scale bottoms out.
;; The tour dives into seahorse valley, so it shows the Mandelbrot set.
(defonce ^:private tour-timer (atom nil))

(rf/reg-fx
 :fractal/tour
 (fn [on?]
   (when-let [t @tour-timer] (js/clearInterval t) (reset! tour-timer nil))
   (when on? (reset! tour-timer (js/setInterval #(rf/dispatch [::tour-tick]) 50)))))

(rf/reg-event-fx
 ::toggle-tour
 (fn [{:keys [db]} _]
   (let [on? (not (:tour? db))]
     {:db (cond-> (assoc db :tour? on?)
            on? (-> (assoc :fractal view/default-fractal) fit-engines))
      :fx [[:fractal/tour on?]]})))

(rf/reg-event-fx ::stop-tour (fn [{:keys [db]} _] {:db (assoc db :tour? false) :fx [[:fractal/tour false]]}))

(rf/reg-event-fx
 ::tour-tick
 (fn [{:keys [db]} _]
   (let [v (view/tour-step (:view db))
         db' (assoc db :view v :iter (view/tour-iter v (:iter db)))]
     (if (< (:scale v) 1e-13)
       (-> (repaint (assoc db' :tour? false)) (update :fx conj [:fractal/tour false]))
       (repaint db')))))

;; --- bench -------------------------------------------------------------------------
(def bench-views
  "[name cx cy scale-per-256px iter fractal]. A view runs on the engines that
  render its fractal; the others show n/a."
  [["full set" -0.6 0.0 (/ 3.0 256) 256 view/default-fractal]
   ["seahorse valley" -0.745 0.112 (/ 0.008 256) 512 view/default-fractal]
   ["spiral" -0.10109636384562 0.95628651080914 (/ 0.0005 256) 1024 view/default-fractal]
   ["deep pinch" -1.768778833 0.001738996 (/ 1e-6 256) 1024 view/default-fractal]
   ["burning ship" -1.762 -0.028 (/ 0.06 256) 512 {:formula "burning-ship" :julia nil}]
   ["multibrot3 julia" 0.0 0.0 (/ 3.4 256) 512 {:formula "multibrot3" :julia [-0.2 0.75]}]])

(defn parity?
  "On each view, every exact engine that rendered it gave the same iteration
  total and checksum. A view no exact engine renders is vacuously in parity."
  [rows views]
  (every? (fn [[name]]
            (let [rs (filter #(and (= name (:view %)) (:exact? %) (not (:error %)) (not (:skipped %))) rows)]
              (or (empty? rs) (apply = (map (juxt :iters :checksum) rs)))))
          views))

(defn run-bench!
  "Render every view on every engine that renders it, one at a time; dispatch
  each row as it lands. Resolves to {:w :h :engines :views :rows :parity}."
  [{:keys [engines w h views] :or {w 256 h 192 views bench-views}}]
  (rf/dispatch [::bench-start {:w w :h h :engines engines :views views}])
  (let [jobs (for [[name cx cy sc it f] views, e engines]
               [name e (merge {:cx cx :cy cy :scale (* sc (/ 256 w)) :w w :h h} f) it])]
    (-> (reduce (fn [p [name e tile it]]
                  (.then p (fn [rows]
                             (-> (if (engines/renders? (get @engines/registry e) tile)
                                   (-> (engines/render-on e tile it)
                                       (.then (fn [{:keys [pixels ms iters]}]
                                                {:view name :engine e :ms ms :iters iters
                                                 :exact? (engines/exact-engine? e)
                                                 :mits (view/mits iters ms) :checksum (engines/checksum pixels)}))
                                       (.catch (fn [err] {:view name :engine e :error (.-message err)})))
                                   (js/Promise.resolve {:view name :engine e :skipped true}))
                                 (.then (fn [row] (rf/dispatch [::bench-row row]) (conj rows row)))))))
                (js/Promise.resolve [])
                jobs)
        (.then (fn [rows]
                 (let [result {:w w :h h :engines engines :views (mapv first views) :rows rows
                               :parity (parity? rows views)}]
                   (rf/dispatch [::bench-done (:parity result)])
                   result))))))

(rf/reg-fx :fractal/bench (fn [opts] (run-bench! opts)))

(rf/reg-event-fx ::bench (fn [{:keys [db]} _] {:fx [[:fractal/bench {:engines (:engines db)}]]}))
(rf/reg-event-db ::bench-start (fn [db [_ meta]] (assoc db :bench (assoc meta :rows [] :parity nil))))
(rf/reg-event-db ::bench-row (fn [db [_ row]] (update-in db [:bench :rows] conj row)))
(rf/reg-event-db ::bench-done (fn [db [_ p]] (assoc-in db [:bench :parity] p)))

;; --- subscriptions ---------------------------------------------------------------
(doseq [k [:view :iter :res :split? :engines :caps :left :right :canvas :panes :totals :samples
           :bench :tour? :ready? :fractal :catalog]]
  (rf/reg-sub k (fn [db _] (get db k))))
