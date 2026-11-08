(ns fractal.events
  "re-frame state: events, effects and subscriptions. The canvas paint is an
  effect (:fractal/paint), latest-wins with one frame in flight per pane."
  (:require [re-frame.core :as rf]
            [fractal.engines :as engines]
            [fractal.view :as view]))

(def initial-db
  {:view view/home :iter 256 :res 1 :split? false
   :engines [] :left nil :right nil :canvas [0 0]
   :panes {} :totals {} :samples {}
   :bench nil :tour? false :ready? false})

;; --- painting -------------------------------------------------------------------
(defonce canvas-el (atom nil))
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
    (let [{:keys [engine view canvas slice res iter]} job
          [W H] canvas
          [dx dw] slice
          pv (view/pane-view view canvas slice res)]
      (swap! pane-state assoc id {:busy? true})
      (-> (engines/render-on engine pv iter)
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
 (fn [{:keys [view canvas split? left right res iter]}]
   (let [[W H] canvas]
     (when (and (>= W 8) (>= H 8) left)
       (let [lw (if split? (js/Math.floor (/ W 2)) W)
             job {:view view :canvas canvas :res res :iter iter}]
         (paint-pane! :L (assoc job :engine left :slice [0 lw]))
         (when (and split? right)
           (paint-pane! :R (assoc job :engine right :slice [lw (- W lw)]))))))))

(rf/reg-fx
 :fractal/hash
 (fn [[v iter]] (js/history.replaceState nil "" (view/->hash v iter))))

(defn- repaint [db]
  {:db db
   :fx [[:fractal/paint (select-keys db [:view :canvas :split? :left :right :res :iter])]
        [:fractal/hash [(:view db) (:iter db)]]]})

;; --- events ----------------------------------------------------------------------
(rf/reg-event-db ::init (fn [_ _] initial-db))

(rf/reg-event-fx
 ::engines-loaded
 (fn [{:keys [db]} [_ loaded]]
   (let [names (engines/names loaded)]
     (repaint (assoc db :engines names :ready? true
                     :left (first names)
                     :right (or (first (filter #(.startsWith % "server-") names)) (first names)))))))

(rf/reg-event-fx ::canvas-size (fn [{:keys [db]} [_ wh]] (repaint (assoc db :canvas wh))))

(rf/reg-event-fx
 ::set-view
 (fn [{:keys [db]} [_ v]]
   (let [merged (merge (:view db) (select-keys v [:cx :cy :scale]))]
     (repaint (cond-> db
                (view/valid? merged) (assoc :view merged)
                (:iter v) (assoc :iter (max 1 (js/Math.round (:iter v)))))))))

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

(rf/reg-event-fx ::reset (fn [{:keys [db]} _] (repaint (assoc db :view view/home :tour? false))))

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
     {:db (assoc db :tour? on?) :fx [[:fractal/tour on?]]})))

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
  [["full set" -0.6 0.0 (/ 3.0 256) 256]
   ["seahorse valley" -0.745 0.112 (/ 0.008 256) 512]
   ["spiral" -0.10109636384562 0.95628651080914 (/ 0.0005 256) 1024]
   ["deep pinch" -1.768778833 0.001738996 (/ 1e-6 256) 1024]])

(defn parity?
  "Every exact engine gave the same iteration total and checksum on each view."
  [rows views]
  (every? (fn [[name]]
            (let [rs (filter #(and (= name (:view %)) (:exact? %) (not (:error %))) rows)]
              (and (seq rs) (apply = (map (juxt :iters :checksum) rs)))))
          views))

(defn run-bench!
  "Render every view on every engine, one at a time; dispatch each row as it
  lands. Resolves to {:w :h :engines :rows :parity}."
  [{:keys [engines w h views] :or {w 256 h 192 views bench-views}}]
  (rf/dispatch [::bench-start {:w w :h h :engines engines :views views}])
  (let [jobs (for [[name cx cy sc it] views, e engines] [name e {:cx cx :cy cy :scale sc :w w :h h} it])]
    (-> (reduce (fn [p [name e pv it]]
                  (.then p (fn [rows]
                             (-> (engines/render-on e pv it)
                                 (.then (fn [{:keys [pixels ms iters]}]
                                          {:view name :engine e :ms ms :iters iters
                                           :exact? (engines/exact-engine? e)
                                           :mits (/ iters ms 1000) :checksum (engines/checksum pixels)}))
                                 (.catch (fn [err] {:view name :engine e :error (.-message err)}))
                                 (.then (fn [row] (rf/dispatch [::bench-row row]) (conj rows row)))))))
                (js/Promise.resolve [])
                jobs)
        (.then (fn [rows]
                 (let [result {:w w :h h :engines engines :rows rows :parity (parity? rows views)}]
                   (rf/dispatch [::bench-done (:parity result)])
                   result))))))

(rf/reg-fx :fractal/bench (fn [opts] (run-bench! opts)))

(rf/reg-event-fx ::bench (fn [{:keys [db]} _] {:fx [[:fractal/bench {:engines (:engines db)}]]}))
(rf/reg-event-db ::bench-start (fn [db [_ meta]] (assoc db :bench (assoc meta :rows [] :parity nil))))
(rf/reg-event-db ::bench-row (fn [db [_ row]] (update-in db [:bench :rows] conj row)))
(rf/reg-event-db ::bench-done (fn [db [_ p]] (assoc-in db [:bench :parity] p)))

;; --- subscriptions ---------------------------------------------------------------
(doseq [k [:view :iter :res :split? :engines :left :right :canvas :panes :totals :samples :bench :tour? :ready?]]
  (rf/reg-sub k (fn [db _] (get db k))))
