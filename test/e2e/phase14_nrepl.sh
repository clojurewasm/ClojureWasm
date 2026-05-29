#!/usr/bin/env bash
# test/e2e/phase14_nrepl.sh
#
# Phase 14 §9.16 row 14.10 — `cljw nrepl` minimal nREPL server
# (F142 re-introduction) per ADR-0015 amendment 2 + ADR-0048
# nREPL chart. Single concurrent session, 4 ops (clone / describe /
# eval / close).
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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

echo
echo "Phase 14 row 14.10 nREPL minimal e2e: all green."
