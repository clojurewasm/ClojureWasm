(def ^{:doc "documented" :private false :custom :m} x 1)
(prn (select-keys (meta #'x) [:doc :custom :name]))
(prn (meta (with-meta [1 2] {:k :v})))
(prn (:tag (meta (with-meta 'sym {:tag 'String}))))
;; Metadata must not participate in equality.
(prn (= (with-meta [1] {:a 1}) (with-meta [1] {:b 2})))
