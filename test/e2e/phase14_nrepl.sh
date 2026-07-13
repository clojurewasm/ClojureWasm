#!/usr/bin/env bash
# test/e2e/phase14_nrepl.sh
#
# Phase 14 §9.16 row 14.10 + ADR-0170 — `cljw nrepl` server, base
# nREPL protocol at CIDER fidelity. Ops: clone / describe / eval /
# load-file / interrupt / ls-sessions / close / completions /
# complete / lookup / info / eldoc, plus stdout (println / pr)
# streamed to the client as `out`. The nREPL wire contract is fixed
# by the real CIDER/nREPL spec, so these cases pin cljw against it:
# start the server, send the bencode op, assert the expected
# response shape comes back. Case 4 replays the CIDER connect
# sequence that the pre-ADR-0170 server failed (pipelined requests,
# >4KiB frames, distinct sessions, the 3-message error protocol) —
# the old single-session happy path stayed green while real CIDER
# was broken, so these assertions are the anti-proxy regression net.
#
# Uses Python's socket module to drive the protocol — neither nc nor
# ncat is reliably present everywhere and a python3 dependency is
# already required by other parts of the dev flow. The script
# launches the server in the background on a random high port, waits
# for the `.nrepl-port` file, sends one bencode-encoded `eval`
# request, asserts the `value` response is "3".

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; exit 1; }

# Pick a random high port to avoid CI collisions.
PORT=$(( 19000 + (RANDOM % 1000) ))
PORT_FILE=$(pwd)/.nrepl-port
rm -f "$PORT_FILE"

# Background the server; redirect output so test stays clean.
"$BIN" nrepl --port "$PORT" > /tmp/cljw_nrepl_stdout.$$ 2> /tmp/cljw_nrepl_stderr.$$ &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; rm -f "$PORT_FILE" /tmp/cljw_nrepl_*.$$' EXIT

# Wait up to 5s for .nrepl-port file (= bound + writing port file).
deadline=$((SECONDS + 5))
while [[ ! -f "$PORT_FILE" ]] && [[ $SECONDS -lt $deadline ]]; do
    sleep 0.1
done
[[ -f "$PORT_FILE" ]] || fail "nrepl_port_file: .nrepl-port not created within 5s"
echo "PASS nrepl_port_file -> $(cat "$PORT_FILE")"

# SE-9: the nREPL server binds LOOPBACK (127.0.0.1) by default, never 0.0.0.0.
# nREPL is unauthenticated remote-eval, so this secure default is load-bearing —
# lock it so a future "expose nREPL" change can't silently make eval reachable
# from the network. Asserted via the startup banner (reflects the bind host).
startup=$(cat "/tmp/cljw_nrepl_stdout.$$" 2>/dev/null || true)
echo "$startup" | grep -q "127.0.0.1" || fail "nrepl_loopback: startup did not declare 127.0.0.1: $startup"
if echo "$startup" | grep -q "0.0.0.0"; then fail "nrepl_loopback: server bound 0.0.0.0 — unauthenticated remote-eval exposed: $startup"; fi
echo "PASS nrepl-loopback-default -> 127.0.0.1"

# --- Case 2: eval (+ 1 2) returns value="3" via Python driver ---
result=$(python3 - "$PORT" <<'PY'
import socket, sys

def encode(v):
    if isinstance(v, int): return f"i{v}e".encode()
    if isinstance(v, (bytes, str)):
        b = v.encode() if isinstance(v, str) else v
        return f"{len(b)}:".encode() + b
    if isinstance(v, list): return b"l" + b"".join(encode(x) for x in v) + b"e"
    if isinstance(v, dict):
        out = b"d"
        for k in sorted(v.keys()):
            out += encode(k) + encode(v[k])
        return out + b"e"
    raise ValueError(type(v))

def decode(buf, i=0):
    c = buf[i:i+1]
    if c == b"i":
        j = buf.index(b"e", i); return int(buf[i+1:j]), j+1
    if c.isdigit():
        j = buf.index(b":", i); n = int(buf[i:j]); return buf[j+1:j+1+n], j+1+n
    if c == b"l":
        i += 1; out = []
        while buf[i:i+1] != b"e":
            v, i = decode(buf, i); out.append(v)
        return out, i+1
    if c == b"d":
        i += 1; out = {}
        while buf[i:i+1] != b"e":
            k, i = decode(buf, i); v, i = decode(buf, i); out[k.decode()] = v
        return out, i+1
    raise ValueError(buf[i:i+4])

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(encode({"op": "eval", "code": "(+ 1 2)", "id": "1"}))
buf = b""
deadline = 5.0
import time
t0 = time.time()
results = []
while time.time() - t0 < deadline:
    chunk = s.recv(4096)
    if not chunk: break
    buf += chunk
    try:
        # Try to consume zero or more dicts.
        i = 0
        while i < len(buf):
            v, j = decode(buf, i)
            results.append(v)
            i = j
        buf = b""
    except (ValueError, IndexError):
        continue
    # Check if any response has status containing "done".
    if any(b"done" in (r.get("status", []) if isinstance(r, dict) else []) for r in results):
        break
s.close()
# Find the value entry.
for r in results:
    if isinstance(r, dict) and "value" in r:
        v = r["value"]
        print(v.decode() if isinstance(v, bytes) else v)
        sys.exit(0)
print("NO_VALUE", file=sys.stderr)
sys.exit(1)
PY
) || fail "nrepl_eval: python driver failed (server output: $(tail -5 /tmp/cljw_nrepl_stderr.$$ 2>/dev/null))"

[[ "$result" == "3" ]] || fail "nrepl_eval: expected value '3', got '$result'"
echo "PASS nrepl_eval_plus_1_2 -> 3"

# --- Case 3: CIDER ops — load-file, out routing, interrupt, ls-sessions,
# describe. One python driver: clone a session, then drive each op and assert
# the response shape matches the nREPL/CIDER contract. ---
python3 - "$PORT" <<'PY' || fail "nrepl_cider_ops: $(tail -5 /tmp/cljw_nrepl_stderr.$$ 2>/dev/null)"
import socket, sys, time

def encode(v):
    if isinstance(v, int): return f"i{v}e".encode()
    if isinstance(v, (bytes, str)):
        b = v.encode() if isinstance(v, str) else v
        return f"{len(b)}:".encode() + b
    if isinstance(v, list): return b"l" + b"".join(encode(x) for x in v) + b"e"
    if isinstance(v, dict):
        out = b"d"
        for k in sorted(v.keys()): out += encode(k) + encode(v[k])
        return out + b"e"
    raise ValueError(type(v))

def decode(buf, i=0):
    c = buf[i:i+1]
    if c == b"i":
        j = buf.index(b"e", i); return int(buf[i+1:j]), j+1
    if c.isdigit():
        j = buf.index(b":", i); n = int(buf[i:j]); return buf[j+1:j+1+n], j+1+n
    if c == b"l":
        i += 1; out = []
        while buf[i:i+1] != b"e":
            v, i = decode(buf, i); out.append(v)
        return out, i+1
    if c == b"d":
        i += 1; out = {}
        while buf[i:i+1] != b"e":
            k, i = decode(buf, i); v, i = decode(buf, i); out[k.decode()] = v
        return out, i+1
    raise ValueError(buf[i:i+4])

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5); s.settimeout(3)

def roundtrip(msg):
    """Send one op; collect every response dict up to a `done` status."""
    s.sendall(encode(msg))
    buf, msgs, t0 = b"", [], time.time()
    while time.time() - t0 < 4.0:
        try: chunk = s.recv(4096)
        except socket.timeout: break
        if not chunk: break
        buf += chunk
        try:
            i = 0
            while i < len(buf):
                v, j = decode(buf, i); msgs.append(v); i = j
            buf = b""
        except (ValueError, IndexError):
            continue
        if any(isinstance(r, dict) and b"done" in r.get("status", []) for r in msgs):
            break
    return msgs

def s_of(d, k):
    v = d.get(k); return v.decode() if isinstance(v, bytes) else v

# Handshake: clone → a session id.
clone = roundtrip({"op": "clone", "id": "c1"})
session = next((s_of(r, "new-session") for r in clone if isinstance(r, dict) and "new-session" in r), None)
assert session, f"clone: no new-session: {clone}"
print(f"PASS nrepl_clone -> {session[:8]}")

# describe must advertise the new ops (the CIDER capability handshake).
desc = roundtrip({"op": "describe", "session": session, "id": "d1"})
ops = next((r.get("ops") for r in desc if isinstance(r, dict) and "ops" in r), {})
opkeys = set(ops.keys()) if isinstance(ops, dict) else set()
for need in ("eval", "load-file", "interrupt", "ls-sessions"):
    assert need in opkeys, f"describe: op '{need}' not advertised: {sorted(opkeys)}"
print(f"PASS nrepl_describe_advertises -> {sorted(opkeys)}")

# eval with println: an `out` response carrying the stdout, then the value.
ev = roundtrip({"op": "eval", "session": session, "code": '(println "hi-nrepl") 7', "id": "e1"})
outs = [s_of(r, "out") for r in ev if isinstance(r, dict) and "out" in r]
vals = [s_of(r, "value") for r in ev if isinstance(r, dict) and "value" in r]
assert any("hi-nrepl" in (o or "") for o in outs), f"eval: stdout not streamed as out: {ev}"
assert "7" in vals, f"eval: value 7 missing: {vals}"
print(f"PASS nrepl_eval_out_routing -> out={outs} value=7")

# load-file: run a whole buffer, get ONLY the last form's value (clj semantics).
lf = roundtrip({"op": "load-file", "session": session,
                "file": '(def yy 3) (println "loaded") (+ yy 39)',
                "file-name": "t.clj", "file-path": "/tmp/t.clj", "id": "l1"})
lvals = [s_of(r, "value") for r in lf if isinstance(r, dict) and "value" in r]
louts = [s_of(r, "out") for r in lf if isinstance(r, dict) and "out" in r]
assert lvals == ["42"], f"load-file: expected only last value ['42'], got {lvals}"
assert any("loaded" in (o or "") for o in louts), f"load-file: stdout not streamed: {lf}"
print(f"PASS nrepl_load_file -> value=42 (last only), out={louts}")

# interrupt: acked with a clean done status, no error.
it = roundtrip({"op": "interrupt", "session": session, "id": "i1"})
assert any(isinstance(r, dict) and b"done" in r.get("status", []) for r in it), f"interrupt: no done: {it}"
assert not any(isinstance(r, dict) and b"error" in r.get("status", []) for r in it), f"interrupt: errored: {it}"
print("PASS nrepl_interrupt_ack")

# ls-sessions: a non-empty sessions list including ours.
ls = roundtrip({"op": "ls-sessions", "session": session, "id": "s1"})
sessions = next((r.get("sessions") for r in ls if isinstance(r, dict) and "sessions" in r), [])
assert sessions, f"ls-sessions: empty: {ls}"
print(f"PASS nrepl_ls_sessions -> {len(sessions)} session(s)")

s.close()
PY

# --- Case 4: ADR-0170 CIDER-fidelity replay — the exact behaviours real
# CIDER depends on that the pre-rearchitecture server failed. One driver:
# distinct clone ids + session echo, pipelined burst (no off-by-one
# stranding), >4KiB frames (no connection reset), the babashka-style
# 3-message error protocol with the CLI-grade rich rendering,
# completions / lookup / eldoc, describe deriving ops + real version,
# ns-honoring + per-session ns isolation, *1/*2/*3 history. ---
python3 - "$PORT" "$("$BIN" --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" <<'PY' || fail "nrepl_cider_fidelity: $(tail -5 /tmp/cljw_nrepl_stderr.$$ 2>/dev/null)"
import socket, sys, time

def encode(v):
    if isinstance(v, int): return f"i{v}e".encode()
    if isinstance(v, (bytes, str)):
        b = v.encode() if isinstance(v, str) else v
        return f"{len(b)}:".encode() + b
    if isinstance(v, list): return b"l" + b"".join(encode(x) for x in v) + b"e"
    if isinstance(v, dict):
        out = b"d"
        for k in sorted(v.keys()): out += encode(k) + encode(v[k])
        return out + b"e"
    raise ValueError(type(v))

def decode(buf, i=0):
    c = buf[i:i+1]
    if c == b"i":
        j = buf.index(b"e", i); return int(buf[i+1:j]), j+1
    if c.isdigit():
        j = buf.index(b":", i); n = int(buf[i:j]); return buf[j+1:j+1+n], j+1+n
    if c == b"l":
        i += 1; out = []
        while buf[i:i+1] != b"e":
            v, i = decode(buf, i); out.append(v)
        return out, i+1
    if c == b"d":
        i += 1; out = {}
        while buf[i:i+1] != b"e":
            k, i = decode(buf, i); v, i = decode(buf, i); out[k.decode()] = v
        return out, i+1
    raise ValueError(buf[i:i+4])

port = int(sys.argv[1])
real_version = sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=5); s.settimeout(3)
buf = b""

def drain(want_ids, deadline_s=4.0):
    """Collect response dicts until every id in want_ids has a done status."""
    global buf
    msgs, t0, pending = [], time.time(), set(want_ids)
    while pending and time.time() - t0 < deadline_s:
        i = 0
        try:
            while i < len(buf):
                v, j = decode(buf, i); msgs.append(v); i = j
                if isinstance(v, dict) and b"done" in v.get("status", []):
                    pending.discard(s_of(v, "id"))
        except (ValueError, IndexError):
            pass  # partial message — keep the tail, read more
        buf = buf[i:]
        if not pending: break
        try: chunk = s.recv(65536)
        except socket.timeout: break
        if not chunk: raise AssertionError("server closed connection")
        buf += chunk
    assert not pending, f"no done for ids {pending}: {msgs}"
    return msgs

def s_of(d, k):
    v = d.get(k); return v.decode() if isinstance(v, bytes) else v

def rt(msg):
    s.sendall(encode(msg)); return drain([msg["id"]])

# 4a. Distinct sessions per clone + echo of the request session in replies.
c1 = rt({"op": "clone", "id": "f1"})
c2 = rt({"op": "clone", "id": "f2"})
main_s = next(s_of(r, "new-session") for r in c1 if isinstance(r, dict) and "new-session" in r)
tool_s = next(s_of(r, "new-session") for r in c2 if isinstance(r, dict) and "new-session" in r)
assert main_s != tool_s, f"clone must mint distinct sessions: {main_s} == {tool_s}"
ev = rt({"op": "eval", "session": main_s, "code": "(+ 20 22)", "id": "f3"})
echoed = {s_of(r, "session") for r in ev if isinstance(r, dict)}
assert echoed == {main_s}, f"replies must echo the REQUEST session {main_s}: {echoed}"
print("PASS nrepl_distinct_sessions_and_echo")

# 4b. Pipelined burst: 3 requests in ONE TCP write — all answered without
# further client writes (the pre-ADR-0170 loop stranded them off-by-one).
s.sendall(encode({"op": "eval", "session": main_s, "code": "1", "id": "p1"})
          + encode({"op": "eval", "session": main_s, "code": "2", "id": "p2"})
          + encode({"op": "eval", "session": tool_s, "code": "3", "id": "p3"}))
pm = drain(["p1", "p2", "p3"])
pvals = {s_of(r, "id"): s_of(r, "value") for r in pm if isinstance(r, dict) and "value" in r}
assert pvals == {"p1": "1", "p2": "2", "p3": "3"}, f"pipelined values wrong: {pvals}"
p3sess = {s_of(r, "session") for r in pm if isinstance(r, dict) and s_of(r, "id") == "p3"}
assert p3sess == {tool_s}, f"p3 must be stamped with the tooling session: {p3sess}"
print("PASS nrepl_pipelined_burst")

# 4c. >4KiB frame: must evaluate, not reset the connection.
big = "(str " + " ".join('"%s"' % ("x" * 50) for _ in range(200)) + ")"
bm = rt({"op": "eval", "session": main_s, "code": big, "id": "big1"})
bval = next(s_of(r, "value") for r in bm if isinstance(r, dict) and "value" in r)
assert len(bval) > 4096, f"big eval value truncated: len={len(bval)}"
print("PASS nrepl_large_frame")

# 4d. Error protocol: rich err text (the CLI caret rendering, not a bare
# Zig error name), a SEPARATE ex/root-ex + eval-error dict, exactly ONE
# done, and NO evaluation of the forms after the failing one.
em = rt({"op": "eval", "session": main_s, "code": "hoge (def poisoned 1)", "id": "err1"})
errs = [s_of(r, "err") for r in em if isinstance(r, dict) and "err" in r]
assert any("Unable to resolve symbol" in (e or "") for e in errs), f"err lacks rich message: {errs}"
for r in em:
    if isinstance(r, dict) and "err" in r:
        assert b"done" not in r.get("status", []), f"err bundled with done: {r}"
exd = [r for r in em if isinstance(r, dict) and "ex" in r]
assert exd and "root-ex" in exd[0] and b"eval-error" in exd[0].get("status", []), f"missing ex/root-ex dict: {em}"
dones = [r for r in em if isinstance(r, dict) and b"done" in r.get("status", [])]
assert len(dones) == 1, f"exactly one done required, got {len(dones)}: {em}"
after = rt({"op": "eval", "session": main_s, "code": "(resolve 'poisoned)", "id": "err2"})
aval = next(s_of(r, "value") for r in after if isinstance(r, dict) and "value" in r)
assert aval == "nil", f"forms after a failing form must not run: (resolve 'poisoned) => {aval}"
print("PASS nrepl_error_protocol")

# 4e. completions: CIDER's exact request shape; candidates carry
# candidate+type; the prefix "ma" must surface clojure.core/map.
cm = rt({"op": "completions", "session": tool_s, "prefix": "ma", "ns": "user", "id": "cmp1"})
cands = next((r.get("completions") for r in cm if isinstance(r, dict) and "completions" in r), None)
assert cands is not None, f"no completions key: {cm}"
names = {s_of(c, "candidate") for c in cands if isinstance(c, dict)}
assert "map" in names, f"'map' not in candidates for prefix 'ma': {sorted(names)[:20]}"
typed = next(c for c in cands if isinstance(c, dict) and s_of(c, "candidate") == "map")
assert s_of(typed, "type") == "function", f"map candidate type: {typed}"
print(f"PASS nrepl_completions -> {len(cands)} candidates")

# 4f. lookup + eldoc: arglists/doc from var metadata (babashka shapes).
lk = rt({"op": "lookup", "session": tool_s, "sym": "map", "ns": "user", "id": "lk1"})
info = next((r.get("info") for r in lk if isinstance(r, dict) and "info" in r), None)
assert isinstance(info, dict), f"lookup must nest under info: {lk}"
assert "arglists-str" in info and s_of(info, "name") == "map", f"lookup info shape: {info}"
el = rt({"op": "eldoc", "session": tool_s, "sym": "map", "ns": "user", "id": "el1"})
eld = next((r for r in el if isinstance(r, dict) and "eldoc" in r), None)
assert eld is not None and isinstance(eld.get("eldoc"), list), f"eldoc shape: {el}"
miss = rt({"op": "eldoc", "session": tool_s, "sym": "no-such-var-zz", "ns": "user", "id": "el2"})
assert any(b"no-eldoc" in r.get("status", []) for r in miss if isinstance(r, dict)), f"eldoc miss must carry no-eldoc: {miss}"
print("PASS nrepl_lookup_eldoc")

# 4g. describe: advertises the completion/lookup ops + reports the REAL
# version (build.zig.zon), never a stale hardcoded literal.
dm = rt({"op": "describe", "session": tool_s, "id": "dsc1"})
dops = next(r.get("ops") for r in dm if isinstance(r, dict) and "ops" in r)
for need in ("completions", "complete", "lookup", "info", "eldoc"):
    assert need in dops, f"describe must advertise '{need}': {sorted(dops.keys())}"
vers = next(r.get("versions") for r in dm if isinstance(r, dict) and "versions" in r)
cljw_v = vers.get("cljw")
cljw_v = cljw_v.decode() if isinstance(cljw_v, bytes) else cljw_v
assert real_version and real_version in str(cljw_v), f"describe version {cljw_v!r} != binary version {real_version!r}"
print(f"PASS nrepl_describe_derived -> cljw {cljw_v}")

# 4h. ns honoring: an eval naming a nonexistent ns fails with
# namespace-not-found (nREPL spec); per-session ns isolation: an in-ns in
# one session must not leak into the other session's current ns.
nf = rt({"op": "eval", "session": main_s, "code": "1", "ns": "no.such.ns", "id": "ns1"})
assert any(b"namespace-not-found" in r.get("status", []) for r in nf if isinstance(r, dict)), f"missing namespace-not-found: {nf}"
rt({"op": "eval", "session": main_s, "code": "(in-ns 'fidelity.probe)", "id": "ns2"})
other = rt({"op": "eval", "session": tool_s, "code": "(str *ns*)", "id": "ns3"})
oval = next(s_of(r, "value") for r in other if isinstance(r, dict) and "value" in r)
assert oval == '"user"', f"tooling session ns polluted by main session in-ns: {oval}"
# qualified form — a fresh in-ns'd namespace has no core refers, so a
# bare `str` does NOT resolve there (clj-parity, oracle-verified).
back = rt({"op": "eval", "session": main_s, "code": "(clojure.core/str clojure.core/*ns*)", "id": "ns4"})
bval2 = next(s_of(r, "value") for r in back if isinstance(r, dict) and "value" in r)
assert bval2 == '"fidelity.probe"', f"main session must keep its in-ns: {bval2}"
print("PASS nrepl_ns_honoring_and_isolation")

# 4i. *1/*2/*3 REPL history vars, per session.
rt({"op": "eval", "session": tool_s, "code": "(+ 40 2)", "id": "h1"})
h = rt({"op": "eval", "session": tool_s, "code": "*1", "id": "h2"})
hval = next(s_of(r, "value") for r in h if isinstance(r, dict) and "value" in r)
assert hval == "42", f"*1 must hold the previous value: {hval}"
print("PASS nrepl_star_history")

s.close()
PY

echo
echo "Phase 14 nREPL e2e (base protocol + ADR-0170 CIDER fidelity): all green."
