#!/usr/bin/env bash
# test/e2e/phase14_nrepl.sh
#
# Phase 14 §9.16 row 14.10 — `cljw nrepl` minimal nREPL server
# (F142 re-introduction) per ADR-0015 amendment 2 + ADR-0048
# nREPL chart. Single concurrent session. Ops: clone / describe /
# eval / load-file / interrupt / ls-sessions / close, plus stdout
# (println / pr) streamed to the client as `out`. The nREPL wire
# contract is fixed by the real CIDER/nREPL spec, so these cases
# pin cljw against it: start the server, send the bencode op,
# assert the expected response shape comes back.
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

echo
echo "Phase 14 row 14.10 nREPL e2e (eval / out / load-file / interrupt / ls-sessions): all green."
