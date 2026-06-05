# ADR-0098 — `cljw.http.server`: cljw's own HTTP server on std.Io.net (Ring-style), activating the `runtime/cljw/` original-surface tree

- **Status**: Proposed → Accepted (2026-06-06)
- **Driven by**: the Clojure/conj 2026 CFP (D-256) — the Playground + edge-demo
  need cljw to serve HTTP itself (the "all-cljw, the runtime hosts its own
  playground + edge app" story). User-directed this session: **orthodox approach,
  not a workaround** (no external Go runner).
- **Pulls forward**: the planned `runtime/cljw/edge/ Server` surface
  (structure_plan.md / feature_name_consistency.md R3, Phase 14+) — activated now
  by user direction. **Relates to**: F-009 (impl/surface split), F-011, D-256.

## Context

cljw had no HTTP server (cw v0 had one, but it is **disabled** in cw v0 itself:
its `run-server`/client raise "temporarily disabled while the std.net → std.Io.net
migration is in progress" — cw v0 was written against pre-0.16 `std.net`, removed
in Zig 0.16, and never migrated). So cw v0 supplies the **API design** (Ring-style
request/response maps, `run-server`/`set-handler!`, a hidden `__handler` var for
GC rooting) but **not** a working 0.16 implementation.

Zig 0.16 networking feasibility was proven end-to-end this session by a standalone
prototype: `std.Io.net.IpAddress.listen(io,…) → Server.accept(io) → Stream →
stream.reader/writer(io,buf).interface → std.http.Server.init(&r,&w) →
receiveHead() → req.respond(body,…)` served real `curl` requests
(`HTTP/1.1 200 OK`). cljw already carries `std.Io.Threaded` io + a Thread base
(agent/future) on native targets, so the runtime substrate is in place.

The Playground needs untrusted-code execution; the **edge-demo** needs a trusted
persistent Clojure web app. An HTTP server in cljw serves the edge-demo directly,
and serves the Playground's HTTP front while still spawning a fresh sandboxed
`cljw -e` subprocess per `/run` (isolation stays at the process/microVM boundary,
not in-process eval).

## Decision

**Activate the `src/runtime/cljw/` original-surface tree and implement
`cljw.http.server` on `std.Io.net` + `std.http.Server`, Ring-style.**

1. **Surface**: `cljw.http.server` (implemented) + `cljw.http.client` (placeholder
   stub — each fn raises `feature_not_supported`, reserving the name + the split;
   a transient stub per provisional_marker.md, NOT a permanent no-op). Registered
   as host namespaces (interned builtin fns), so `(require '[cljw.http.server :as
   srv])` resolves them via the already-loaded-ns path (evalRequire: `findNs` with
   `mappings.count() > 0` skips the `.clj` load — same as `clojure.set`).
2. **API (Ring)**: `(run-server handler {:port N})` where `handler` is
   `(fn [req] resp)`. Request map: `{:request-method :get :uri "/path"
   :query-string "..." :headers {"h" "v" …} :body "…"}`. Response map:
   `{:status 200 :headers {…} :body "…"}`. `run-server` blocks the calling thread
   serving a serial accept loop (the server IS the process for deploy;
   per-connection threading + a non-blocking stop-fn handle are a follow-on).
3. **GC rooting**: the handler Value is held live for the server's lifetime (an
   Env/Runtime-rooted slot), so a collect mid-serve cannot sweep it.
4. **Naming rationale** (ecosystem-grounded, user-decided): Clojure / Java /
   Python / Babashka all **split server vs client** (`org.httpkit.server` vs
   `org.httpkit.client` / `babashka.http-client`; `http.server` vs `http.client`;
   `java.net.http` client vs `httpserver`); only Node/Go fold both into one `http`.
   cljw is Clojure-flavoured → split + **Ring** maps + the `run-server` name
   (http-kit/babashka familiarity). Bare `cljw.http` is rejected as ambiguous.
   **`cljw.edge` is reserved** for an edge-DEPLOYMENT convenience layer, NOT the
   HTTP primitive (don't conflate "HTTP server" with "edge deployment").

## Alternatives considered

(The user actively steered each choice this session — the adversarial/fresh-context
check the DA-fork normally provides was supplied by the user's direction + the
ecosystem research, not the loop's momentum.)

- **External Go runner** (Go-Playground model: a tiny Go HTTP server spawning
  `cljw -e`). Fastest to a deploy, cljw unchanged. **Rejected by the user** as a
  workaround — not orthodox; introduces a non-cljw dependency; doesn't serve the
  edge-demo's "Clojure web app" story.
- **wasm port (cljw→wasm, browser-side Playground)**. The CFP_v2 "server-less =
  safe" path, but needs the 3-blocker wasm32 port (threads / u64 atomics /
  NaN-box 8-align). Deferred — heavier; this ADR's native server is orthogonal and
  can coexist (a wasm Playground later reuses the same Ring handlers).
- **Bare `cljw.http`** (Node/Go style, one ns both ways) — ambiguous (the
  "http = client or server?" problem); rejected for the split.
- **`cljw.edge` as the HTTP server name** — conflates HTTP with edge deployment;
  reserved instead for the deployment layer.
- **Per-connection threading + stop-fn handle now** — deferred; serial blocking is
  correct + simplest for the deploy shape (server = process). Concurrency is a
  follow-on (cljw has the Thread base).

## Affected files

- `src/runtime/cljw/http/server.zig` — the std.Io.net + std.http.Server impl
  (listen/accept/serve loop, request→Ring-map, response-map→HTTP).
- `src/runtime/cljw/http/client.zig` — placeholder stub (`feature_not_supported`).
- `src/lang/primitive/cljw_http.zig` — the `run-server` builtin (rt/env/args
  bridge: build req Value, `invokeCallable` the handler, render resp) + the
  `register(env)` that creates the `cljw.http.server` / `cljw.http.client` host
  namespaces; wired into `primitive.registerAll`.
- `test/e2e/phase16_http_server.sh` — bg `cljw` server process + `curl` + assert.
- (`.dev/structure_plan.md` note: `runtime/cljw/` activated ahead of Phase 14.)

## Consequences

- cljw can host its own Playground front + edge web app — no external runner; the
  "all-cljw runtime serves itself" CFP narrative.
- `cljw.http.client` name is reserved (stub) for a later client (Ring-style maps).
- Serial blocking server is correct for the deploy shape; concurrency + a
  non-blocking stop handle are tracked follow-ons (a debt row at land time).
- The Playground still spawns a sandboxed `cljw -e` subprocess per request —
  isolation stays at the OS/microVM boundary, not in the server process.
