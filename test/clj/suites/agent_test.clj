;; Agents (ADR-0093, ADR-0155): send / send-off / await, error modes, watches,
;; *agent*, release-pending-sends, the executor-shaped fns that raise, and
;; binding conveyance. Engine: runtime/agent.zig (single-drainer handoff);
;; surface: lang/primitive/agent.zig + core.clj `await`.
;;
;; Migrated from test/e2e/phase16_agent.sh, which paid one process per case.
;; The script's marker names are kept in the assertion messages.
;;
;; `shutdown-agents` is PROCESS-GLOBAL: run in this shared suite image it would
;; drop every later suite's sends. Those cases (and only those) run in a child
;; cljw, which is what the script's "each -e is a fresh process" relied on.
(ns suites.agent-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.shell :refer [sh]]))

(defn- await-failed
  "Poll until `a` has failed, bounded: synchronises with the async drainer."
  [a]
  (loop [n 0]
    (when (and (nil? (agent-error a)) (< n 400))
      (Thread/sleep 5)
      (recur (inc n))))
  a)

(defn- boom [_] (throw (ex-info "boom" {})))

(deftest agent-send-and-await
  (is (= 5 @(agent 5)) "agent_deref")
  (is (= 1 (let [a (agent 0)] (send a inc) (await a) @a)) "agent_send_await")
  (is (= 100 (let [a (agent 0)] (dotimes [_ 100] (send a inc)) (await a) @a))
      "agent_serial_order")
  (is (= 15 (let [a (agent 0)] (send a + 5) (send a * 3) (await a) @a))
      "agent_send_args")
  (is (= '(2 1) (let [a (agent (list))] (send-off a conj 1) (send-off a conj 2) (await a) @a))
      "agent_send_off"))

(deftest agent-concurrency
  (testing "agent_concurrent_sends: 4 threads x 100 sends to ONE agent all land"
    (is (= 400 (let [a (agent 0)]
                 (run! deref (mapv (fn [_] (future (dotimes [_ 100] (send a inc)))) (range 4)))
                 (await a)
                 @a))))
  (testing "agent_concurrent_agents: different agents run independently"
    (is (= [50 50 50 50 50 50 50 50]
           (let [as (mapv (fn [_] (agent 0)) (range 8))]
             (run! (fn [a] (dotimes [_ 50] (send a inc))) as)
             (run! await as)
             (mapv deref as))))))

(deftest agent-options
  (is (= 1 (let [a (agent 0 :validator number?)] (send a inc) (await a) @a))
      "agent_options_validator")
  (is (= {:a 1} (meta (agent 0 :meta {:a 1}))) "agent_options_meta")
  (is (thrown-with-msg? IllegalStateException #"Invalid reference state"
                        (agent -1 :validator pos?))
      "agent_options_validator_reject: the INITIAL value is validated")
  (is (thrown-with-msg? ClassCastException #"expected agent" (send 5 inc))
      "agent_send_nonagent_error"))

(deftest agent-error-modes
  (is (some? (agent-error (await-failed (doto (agent 0) (send boom)))))
      "agent_fail_default: a thrown action fails the agent")
  (is (= :threw (let [a (await-failed (doto (agent 0) (send boom)))]
                  (try (send a inc) :no-throw (catch Throwable _ :threw))))
      "agent_send_to_failed_throws")
  (is (= [11 nil] (let [a (await-failed (doto (agent 0) (send boom)))]
                    (restart-agent a 10) (send a inc) (await a)
                    [@a (agent-error a)]))
      "agent_restart")
  (is (= [1 nil :continue]
         (let [a (agent 0)]
           (set-error-mode! a :continue)
           (send a boom) (send a inc) (await a)
           [@a (agent-error a) (error-mode a)]))
      "agent_continue_mode")
  (is (= :fail (error-mode (agent 0))) "agent_error_mode_default")
  (is (nil? (agent-errors (agent 0))) "agent_errors_nil")
  (is (= [nil 0] (let [a (await-failed (doto (agent 0 :error-mode :fail) (send boom)))]
                   (clear-agent-errors a)
                   [(agent-error a) @a]))
      "clear_agent_errors_failed"))

(deftest agent-nested-send-and-predicate
  ;; The nested send is DEFERRED until the action completes (D-388); two awaits
  ;; observe the full drain deterministically on clj and cljw alike.
  (is (= 2 (let [a (agent 0)] (send a (fn [s] (send a inc) (inc s))) (await a) (await a) @a))
      "agent_nested_send")
  (is (= [true false false] [(agent? (agent 0)) (agent? 5) (agent? (atom 0))])
      "agent_predicate"))

(deftest agent-watches
  (is (= [[0 1] [1 2] [2 2]]
         (let [log (atom []) a (agent 0)]
           (add-watch a :k (fn [_ _ o n] (swap! log conj [o n])))
           (send a inc) (send a inc) (await a)
           @log))
      "agent_add_watch")
  (is (= [1 1]
         (let [log (atom []) a (agent 0)]
           (add-watch a :k (fn [_ _ _ n] (swap! log conj n)))
           (send a inc) (await a) (remove-watch a :k) (send a inc) (await a)
           @log))
      "agent_remove_watch")
  (is (true? (let [seen (atom nil) a (agent 10)]
               (add-watch a :k (fn [_ r _ _] (reset! seen (= r a))))
               (send a inc) (await a)
               @seen))
      "agent_watch_ref_arg"))

(deftest agent-executor-fns-raise
  ;; AD-045 / D-442: cljw has no configurable executor; accepting one silently
  ;; would be a lie.
  (is (thrown-with-msg? IllegalArgumentException #"no configurable executor"
                        (send-via :ex (agent 0) inc))
      "agent_send_via_raises")
  (is (thrown-with-msg? IllegalArgumentException #"no configurable executor"
                        (set-agent-send-executor! :ex))
      "agent_set_executor_raises")
  (is (thrown-with-msg? IllegalArgumentException #"no configurable executor"
                        (set-agent-send-off-executor! :ex))
      "agent_set_off_executor_raises"))

(deftest agent-star-and-pending-sends
  (is (true? (let [a (agent nil)] (send a (fn [_] *agent*)) (await a) (= @a a)))
      "agent_star_in_action")
  (is (nil? *agent*) "agent_star_outside_nil")
  (is (true? (let [seen (atom nil) a (agent 0)]
               (add-watch a :k (fn [_ r _ _] (reset! seen (= r *agent*))))
               (send a inc) (await a)
               @seen))
      "agent_star_in_watch")
  (is (= [1 1] (let [cnt (atom nil) b (agent 0) a (agent 0)]
                 (send a (fn [s] (send b inc) (reset! cnt (release-pending-sends)) s))
                 (await a) (await b)
                 [@cnt @b]))
      "release_pending_sends_in_action")
  (is (= 0 (release-pending-sends)) "release_pending_sends_outside"))

(def ^:dynamic *agent-test-cv* :unset)

(deftest agent-binding-conveyance
  (is (= :caller (let [a (agent nil)]
                   (binding [*agent-test-cv* :caller] (send a (fn [_] *agent-test-cv*)))
                   (await a) @a))
      "agent_send_conveys_bindings")
  (is (= :caller (let [a (agent nil)]
                   (binding [*agent-test-cv* :caller] (send-off a (fn [_] *agent-test-cv*)))
                   (await a) @a))
      "agent_sendoff_conveys_bindings")
  (is (= :unset (let [a (agent nil)] (send a (fn [_] *agent-test-cv*)) (await a) @a))
      "agent_send_no_conveyance_sees_root"))

(defn- child-value
  "Evaluate `script` in a child cljw and answer the last stdout line."
  [script]
  (let [{:keys [out]} (sh "zig-out/bin/cljw" "-e" script)]
    (last (clojure.string/split-lines out))))

(deftest shutdown-agents-is-process-global
  ;; `-e` prints the value of the form, so the child's last line IS the result.
  (is (= "nil" (child-value "(shutdown-agents)")) "shutdown_agents_returns_nil")
  (is (= "true" (child-value "(do (shutdown-agents) (let [a (agent 0)] (identical? a (send a inc))))"))
      "shutdown_agents_send_returns_agent: the dropped send does not throw")
  (is (= "0" (child-value "(do (shutdown-agents) (let [a (agent 0)] (send a inc) (Thread/sleep 100) @a))"))
      "shutdown_agents_action_dropped")
  ;; AD-046: cljw has no RejectedExecutionException to route, so the dropped
  ;; send does NOT fire the :error-handler.
  (is (= "[[] 0]"
         (child-value (str "(let [log (atom []) a (agent 0 :error-handler (fn [_ _] (swap! log conj :fired)))]"
                           " (shutdown-agents) (send a inc) (Thread/sleep 100) [@log @a])")))
      "shutdown_agents_no_handler_fire"))
