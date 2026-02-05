;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

(ns clojure.set)

;; UPSTREAM-DIFF: bubble-max-key removed (identical? doesn't work with copied values);
;; 3+ arg variants use simple reduce instead.

(defn union
  ([] #{})
  ([s1] s1)
  ([s1 s2]
   (if (< (count s1) (count s2))
     (reduce conj s2 s1)
     (reduce conj s1 s2)))
  ([s1 s2 & sets]
   (reduce union (union s1 s2) sets)))

(defn intersection
  ([s1] s1)
  ([s1 s2]
   (if (< (count s2) (count s1))
     (recur s2 s1)
     (reduce (fn [result item]
               (if (contains? s2 item)
                 result
                 (disj result item)))
             s1 s1)))
  ([s1 s2 & sets]
   (reduce intersection (intersection s1 s2) sets)))

(defn difference
  ([s1] s1)
  ([s1 s2]
   (if (< (count s1) (count s2))
     (reduce (fn [result item]
               (if (contains? s2 item)
                 (disj result item)
                 result))
             s1 s1)
     (reduce disj s1 s2)))
  ([s1 s2 & sets]
   (reduce difference s1 (conj sets s2))))

(defn select
  [pred xset]
  (reduce (fn [s k] (if (pred k) s (disj s k)))
          xset xset))

(defn project
  [xrel ks]
  (with-meta (set (map #(select-keys % ks) xrel)) (meta xrel)))

(defn rename-keys
  [map kmap]
  (reduce
   (fn [m [old new]]
     (if (contains? map old)
       (assoc m new (get map old))
       m))
   (apply dissoc map (keys kmap)) kmap))

(defn rename
  [xrel kmap]
  (with-meta (set (map #(rename-keys % kmap) xrel)) (meta xrel)))

(defn index
  [xrel ks]
  (reduce
   (fn [m x]
     (let [ik (select-keys x ks)]
       (assoc m ik (conj (get m ik #{}) x))))
   {} xrel))

(defn map-invert
  [m]
  (persistent!
   (reduce-kv (fn [m k v] (assoc! m v k))
              (transient {})
              m)))

(defn join
  ([xrel yrel]
   (if (and (seq xrel) (seq yrel))
     (let [ks (intersection (set (keys (first xrel))) (set (keys (first yrel))))
           [r s] (if (<= (count xrel) (count yrel))
                   [xrel yrel]
                   [yrel xrel])
           idx (index r ks)]
       (reduce (fn [ret x]
                 (let [found (idx (select-keys x ks))]
                   (if found
                     (reduce #(conj %1 (merge %2 x)) ret found)
                     ret)))
               #{} s))
     #{}))
  ([xrel yrel km]
   (let [[r s k] (if (<= (count xrel) (count yrel))
                   [xrel yrel (map-invert km)]
                   [yrel xrel km])
         idx (index r (vals k))]
     (reduce (fn [ret x]
               (let [found (idx (rename-keys (select-keys x (keys k)) k))]
                 (if found
                   (reduce #(conj %1 (merge %2 x)) ret found)
                   ret)))
             #{} s))))

(defn subset?
  [set1 set2]
  (and (<= (count set1) (count set2))
       (every? #(contains? set2 %) set1)))

(defn superset?
  [set1 set2]
  (and (>= (count set1) (count set2))
       (every? #(contains? set1 %) set2)))
