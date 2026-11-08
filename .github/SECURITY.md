# Security Policy

ClojureWasm (`cljw`) is a Clojure runtime with a **WebAssembly FFI**: it can
load and execute **untrusted `.wasm` bytecode** in the same process as the host
(through the embedded zwasm engine), and — in embeddings that accept
user-submitted code — it evaluates **untrusted Clojure source** in-process.
Memory safety and sandbox integrity are therefore first-class concerns for
anyone running it.

## Supported versions

Fixes land on `main` and ship in the next release. There is no backport branch:
the supported line is the newest release, and upgrading is the fix.

| Version               | Supported |
|-----------------------|-----------|
| `main`                | ✅        |
| latest release        | ✅        |
| any earlier release   | ❌        |

If you are on Homebrew, `brew upgrade buddhilw/tap/cljw` puts you on the
supported line.

This project is maintained by one person, as a fork continuing the archived
[clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm), whose
own final release was v1.10.1. Expect a best-effort response, not a service
level agreement — see the timelines below, which are deliberately honest rather
than reassuring.

The embedded WebAssembly engine, **zwasm**, is a separate project and
[continues under its own maintainership](https://github.com/zwasm/zwasm). A
vulnerability in the engine itself is best reported there, where it can be
fixed at source; report it here as well if `cljw`'s pin or its use of the
embedding API is part of the exposure.

## Reporting a vulnerability

**Please do not open a public Discussion for security problems.**

Report privately via GitHub's **[Private Vulnerability Reporting](https://github.com/BuddhiLW/ClojureWasm/security/advisories/new)**
(the "Report a vulnerability" button under the repository's *Security* tab).
If that is unavailable to you, open a minimal public Discussion asking a
maintainer to reach out — **without any exploit detail** — and mention
`@BuddhiLW`.

Please include, where possible:

- affected version / commit and target (`aarch64-macos`, `x86_64-linux`) and
  execution mode (interpreter / JIT / AOT for the Wasm FFI);
- a minimal reproducer — a `.clj` expression, or a `.wasm` / `.wat` module and
  the exact CLI / embedding call;
- the observed impact (host memory corruption, Wasm sandbox escape, WASI
  capability bypass, denial of service, etc.).

Expect an acknowledgement within a week and, for a confirmed issue in scope, a
fix or a written mitigation in the release after that. If a report goes
unanswered for two weeks, treat this project as unable to respond and disclose
on whatever timeline you judge right — you are under no obligation to wait
longer on a single-maintainer project.

## Scope

In scope: host memory corruption from a malformed or adversarial `.wasm`
module, Wasm sandbox / WASI-capability escapes, JIT code-generation bugs with a
security impact, and memory-safety faults in the Zig runtime reachable from
ordinary Clojure input.

Out of scope: behaviour of untrusted guest code that stays *within* the Wasm
sandbox, resource exhaustion by trusted local scripts you run yourself, and
misuse of the embedding API in ways the documentation warns against.
