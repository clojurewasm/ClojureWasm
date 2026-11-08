(ns fractal.http
  "Boundary: the tile protocol over the JDK's HttpServer. Same routes and
  headers as the cljw server (raw RGBA body, X-Render-Ms, X-Iters), plus CORS,
  so the page on the cljw origin calls this server directly.
    GET /engines   {\"engines\":[...],\"unavailable\":[...]}
    GET /tile?cx=&cy=&scale=&w=&h=&iter=&engine="
  (:require [clojure.string :as str]
            [fractal.renderer :as r]
            [fractal.tile :as tile])
  (:import (com.sun.net.httpserver HttpExchange HttpHandler HttpServer)
           (java.net InetSocketAddress URLDecoder)
           (java.util.concurrent Executors)))

(defn query-map [^String raw]
  (if (str/blank? raw)
    {}
    (into {} (keep (fn [pair]
                     (let [i (.indexOf ^String pair "=")]
                       (when (pos? i)
                         [(subs pair 0 i) (URLDecoder/decode (subs pair (inc i)) "UTF-8")]))))
          (.split raw "&"))))

(defn- json-strings [xs] (str "[" (str/join "," (map #(str "\"" % "\"") xs)) "]"))

(defn engines-json
  "Engines, the inexact ones among them (not held to golden.edn, e.g. fp32),
  and the unavailable ones."
  [registry unavailable]
  (str "{\"engines\":" (json-strings (keys registry))
       ",\"inexact\":" (json-strings (for [[k rr] registry :when (not (:parity? (r/describe rr)))] k))
       ",\"unavailable\":" (json-strings (map :id unavailable)) "}"))

(defn respond
  "Pure: a request {:path :query} to a response {:status :headers :body bytes}."
  [registry unavailable {:keys [path query]}]
  (try
    (case path
      "/engines" {:status 200 :headers {"content-type" "application/json"}
                  :body (.getBytes ^String (engines-json registry unavailable) "UTF-8")}
      "/tile" (let [t (tile/parse-query query)
                    rid (get query "engine" (first (keys registry)))]
                (if-let [rr (get registry rid)]
                  (let [{:keys [ms iters rgba]} (r/frame rr t)]
                    {:status 200
                     :headers {"content-type" "application/octet-stream"
                               "cache-control" "no-store"
                               "x-render-ms" (format "%.3f" ms)
                               "x-iters" (str iters)}
                     :body rgba})
                  {:status 400 :headers {} :body (.getBytes (str "unknown engine " rid) "UTF-8")}))
      {:status 404 :headers {} :body (.getBytes "not found\n" "UTF-8")})
    (catch Exception e
      {:status 400 :headers {} :body (.getBytes (str "tile error: " (.getMessage e)) "UTF-8")})))

(defn- send! [^HttpExchange ex {:keys [status headers ^bytes body]}]
  (let [h (.getResponseHeaders ex)]
    (.add h "access-control-allow-origin" "*")
    (.add h "access-control-expose-headers" "x-render-ms, x-iters")
    (doseq [[k v] headers] (.add h k v))
    (.sendResponseHeaders ex status (alength body))
    (with-open [out (.getResponseBody ex)] (.write out body))))

(defn start!
  "Serve registry on port; returns the HttpServer."
  ^HttpServer [port registry unavailable]
  (doto (HttpServer/create (InetSocketAddress. (int port)) 0)
    (.createContext "/" (reify HttpHandler
                          (handle [_ ex]
                            (let [uri (.getRequestURI ex)]
                              (send! ex (respond registry unavailable
                                                 {:path (.getPath uri) :query (query-map (.getRawQuery uri))}))))))
    (.setExecutor (Executors/newFixedThreadPool 4))
    (.start)))
