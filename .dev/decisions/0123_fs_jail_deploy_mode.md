# ADR-0123 — Opt-in filesystem jail for deploy mode (`CLJW_FS_ROOT`)

- **Status**: Proposed → Accepted (2026-06-09)
- **Resolves**: SE-6 / SE-7 (security audit) — `slurp`/`spit`/`wasm/load` take any
  string path with no confinement; at the edge, request data reaching a path arg
  is arbitrary read/write + `../../etc/passwd` traversal. Discharges D-340 (v1).
- **Schedules**: D-342 (symlink-safe finished form — the Alt-2 below).
- **Composes with**: F-009 (one neutral enforcement point), F-011 (jail OFF by
  default → local-CLI `slurp`/`spit` unchanged; only opt-in deploy mode diverges).

## Context

`slurp`/`spit` (`lang/primitive/file_io.zig`) and `wasm/load` (`wasm/surface.zig`)
— plus `java.io.File` — all route file reads/writes through
`runtime/file_io.zig` `readAll`/`writeAll`. None confine the path. A deployed edge
app that lets request data reach a path argument is an arbitrary-FS-read/write
+ path-traversal primitive. Local CLI use is fine by design (the user owns the
shell). The audit's secure-by-default target: an **opt-in preopen-style FS root**
for deployed mode, off for local CLI.

### Why not the obvious kernel mechanism

Zig 0.16 `std.Io.Dir.openFile` exposes `resolve_beneath`, but it maps to
`posix.O.RESOLVE_BENEATH` via `@hasField` — present **only on FreeBSD**. On macOS
and Linux (cljw's two gate hosts) the option is **silently ignored**. A jail built
on it would be **false security** on every platform cljw actually runs. `std.Io`
`realPath` is itself stdlib-flagged "limited platform support, advisable to avoid
entirely." So the portable mechanism must be **lexical**.

## Decision

A jail root is configured at startup via the `CLJW_FS_ROOT` environment variable
(matching cljw's existing `init.environ_map.get("CLJW_…")` convention). When set,
it is canonicalised ONCE to an absolute `root_abs` (a one-time `realPath` of an
existing directory — loud failure at startup on misconfiguration) and stored on
`Runtime.fs_jail_root` (`?[]const u8`, default `null` = unconfined).

A neutral `file_io.enforceJail(alloc, root_abs, path) !void` is the single policy
point (F-009). Each FS surface (`slurp`/`spit`/`wasm/load`/`java.io.File`) calls it
before the I/O op and maps its error to the catchable catalog Code
`fs_jail_escape` (Kind `.value_error` → IllegalArgumentException). When
`root_abs == null` it is a no-op (local CLI unchanged).

`enforceJail` resolves the user path under the root with
`std.fs.path.resolvePosix(alloc, &.{root_abs, path})` (lexical `.`/`..`
resolution) and requires the result to be `root_abs` itself or strictly beneath
it (`startsWith(resolved, root_abs) and resolved[root_abs.len] == '/'` — the
boundary guard that distinguishes `/jail/x` from a sibling `/jailX`). Otherwise →
`error.FsJailEscape`. A `..`-traversal escape and an absolute path **outside** the
root are both rejected by this containment (an absolute path resets resolvePosix,
then fails the prefix check); an absolute path that lands **inside** the root
resolves to within and is allowed — there is no silent escape in either case. A
non-absolute `root` is a misconfiguration and fails closed (deny all).

### Guarantee + documented residual (this is v1, NOT terminal)

This blocks `..` traversal and absolute-path escape **deterministically and
portably**. It does NOT resolve symlinks, so a symlink *planted inside the jail*
pointing outside is still followed. That residual is **explicit** (here, in the
error text's spirit, and in deploy guidance: mount the jail read-only / forbid
symlinks in it). A jail that does exactly what it documents is honest, not
false-security — the false-security case is the macOS-ignored `resolve_beneath`,
which this deliberately avoids. The symlink-safe finished form (per-component
`openat`-relative resolution / `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)` on
Linux, `O_NOFOLLOW` walk on macOS) is scheduled as **D-342**, not deferred to
"later" — v1 is an honest documented step toward it.

## Consequences

- A deploy sets `CLJW_FS_ROOT=/srv/app/data`; all `slurp`/`spit`/`wasm/load`
  confine to that subtree; traversal/absolute escapes raise a catchable error.
- Local CLI (no env var) is byte-for-byte unchanged (F-011-safe).
- The symlink residual is a known, documented, scheduled (D-342) limitation —
  not a silent gap.

## Alternatives considered

From a fresh-context devil's-advocate fork (F-NNN-constrained), verbatim in
substance:

- **Smallest-diff** — the standalone `enforceJail` lexical check (this ADR's v1).
  Cleanest F-009 split; a ~30-line pure predicate, FS-free unit tests. Its only
  question is the symlink residual (below). Risk if taken as *terminal*: the
  smallest-diff-bias smell.
- **Finished-form-clean** — symlink-safe per-op `openat`/`fstatat`-relative
  resolution (kernel-enforced: `openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS` on
  Linux, `O_NOFOLLOW` per-component walk on macOS) + a Clojure dynamic var
  (`*fs-root*`) layered over the env default for per-request tightening. Closes
  the symlink residual *honestly*. Cost: forces a root dir-handle into
  `file_io.zig` (real surgery, not a thin surface), and the macOS per-component
  walk is fiddly (TOCTOU unless the dirfd is kept). **This is the F-002 finished
  form — adopted as the SCHEDULED target D-342**, with v1 (lexical) shipping now.
- **Wildcard** — a capability-handle model (opening returns an opaque file
  capability; ops take the handle, no path crosses the jail). Eliminates the
  traversal class by construction, but detonates F-011 (JVM `slurp`/`spit` take
  strings); viable only as a *separate* future edge API, not a confinement of the
  named fns. Rejected as the jail; noted as a future edge-API direction.

The DA's binding-free recommendation: ship the lexical v1 **with** explicit
symlink-residual documentation **and** D-342 scheduling Alt 2 — Alt 1 as an honest
documented step, not as terminal. Adopted. The DA also corrected (b)
paths-relative-to-jail-root (preopen, absolute rejected) over cwd-then-contained,
and (e) the exhaustive boundary-test list (prefix boundary, `..` past root,
absolute, empty/`.`/trailing-slash, `root_abs` itself, the symlink-followed
residual asserted so it can't silently change, double-slash) — all adopted.
