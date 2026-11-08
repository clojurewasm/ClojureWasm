#!/usr/bin/env bash
# test/e2e/phase14_nrepl_classpath.sh
#
# D-322 for the nREPL server: a session must resolve `(require '[my.lib])`
# off the filesystem classpath, exactly as `cljw <file>` / `cljw -e` /
# `cljw repl` do. Before this, `cljw nrepl` took no `-cp`, ignored
# $CLJW_PATH, and never called require_resolver.installChained — so an
# editor could evaluate arithmetic but could not load one line of the
# project it was started in.
#
# Three cases, one per rung of the ADR-0084 resolution rule
# (`-cp` wins, else $CLJW_PATH, else "." + ./deps.edn :paths):
#   1. -cp <dir>
#   2. $CLJW_PATH
#   3. neither — ./deps.edn :paths off the cwd
# plus a negative case pinning that unknown args are still rejected.
#
# Same harness shape as phase14_nrepl.sh: launch the server on a random
# high port, drive bencode over a socket from python3, assert the
# `value` frame.

set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

BIN="$ROOT/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

WORK=$(mktemp -d)
SERVER_PID=""
SERVER_PORT=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL $1" >&2; exit 1; }

# A throwaway project: one namespace under src/, declared in deps.edn.
mkdir -p "$WORK/src/cljw_cp_probe"
cat > "$WORK/src/cljw_cp_probe/lib.clj" <<'EOF'
(ns cljw-cp-probe.lib)
(defn answer [] 42)
EOF
cat > "$WORK/deps.edn" <<'EOF'
{:paths ["src"]}
EOF

# Drive one eval over bencode; echoes each `value` frame on its own line.
drive() {
    python3 - "$1" "$2" <<'PY'
import socket, sys, time

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

port, code = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall(encode({"op": "eval", "code": code, "id": "1"}))
buf, t0 = b"", time.time()
while time.time() - t0 < 5:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk: break
    buf += chunk
    if b"done" in buf: break
i = 0
while i < len(buf):
    try:
        m, i = decode(buf, i)
    except Exception:
        break
    if "value" in m: print(m["value"].decode())
    if "err" in m: print("ERR " + m["err"].decode().replace("\n", " "))
PY
}

# Start a server in $WORK and wait for its port file. $1 = port, rest = argv.
start_server() {
    local port="$1"; shift
    rm -f "$WORK/.nrepl-port"
    ( cd "$WORK" && "$BIN" nrepl --port "$port" "$@" >"$WORK/out.log" 2>&1 ) &
    SERVER_PID=$!
    SERVER_PORT="$port"
    local deadline=$((SECONDS + 30))
    while [[ ! -f "$WORK/.nrepl-port" ]] && [[ $SECONDS -lt $deadline ]]; do sleep 0.1; done
    [[ -f "$WORK/.nrepl-port" ]] || fail "server did not bind within 30s: $(cat "$WORK/out.log")"
}

stop_server() {
    # Reap by PORT, not just `$SERVER_PID`: `( cd … && cmd ) &` leaves bash a
    # real subshell, so the server is a GRANDchild and killing $! orphans it.
    # Each leaked server holds memory until the run ends; enough of them and the
    # kernel starts SIGKILLing unrelated processes.
    pkill -f "nrepl --port ${SERVER_PORT}( |$)" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    sleep 0.2
}

CODE='(require (quote [cljw-cp-probe.lib :as p])) (p/answer)'

# --- Case 1: -cp <dir> ---
PORT=$(( 19100 + (RANDOM % 300) ))
start_server "$PORT" -cp src
got=$(drive "$PORT" "$CODE" | tail -1)
stop_server
[[ "$got" == "42" ]] || fail "nrepl_cp_flag: expected 42, got '$got'"
echo "PASS nrepl_cp_flag -> 42"

# --- Case 2: $CLJW_PATH ---
PORT=$(( 19400 + (RANDOM % 300) ))
CLJW_PATH=src start_server "$PORT"
got=$(drive "$PORT" "$CODE" | tail -1)
stop_server
[[ "$got" == "42" ]] || fail "nrepl_cljw_path_env: expected 42, got '$got'"
echo "PASS nrepl_cljw_path_env -> 42"

# --- Case 3: neither — ./deps.edn :paths off the cwd ---
PORT=$(( 19700 + (RANDOM % 300) ))
start_server "$PORT"
got=$(drive "$PORT" "$CODE" | tail -1)
stop_server
[[ "$got" == "42" ]] || fail "nrepl_deps_edn_paths: expected 42, got '$got'"
echo "PASS nrepl_deps_edn_paths -> 42"

# --- Case 4: unknown args are still rejected (the parse loop stays closed) ---
if "$BIN" nrepl --bogus >"$WORK/bogus.log" 2>&1; then
    fail "nrepl_unknown_arg: --bogus was accepted"
fi
grep -q "unknown argument" "$WORK/bogus.log" || fail "nrepl_unknown_arg: no diagnostic: $(cat "$WORK/bogus.log")"
echo "PASS nrepl_unknown_arg -> rejected"

echo "ALL PASS test/e2e/phase14_nrepl_classpath.sh"
