#!/usr/bin/env bash
# test/e2e/phase14_nrepl_toplevel_do.sh
#
# A top-level `do` must be unrolled before analysis on EVERY entry point,
# not just the script/`-e` one. `runner.runSource` calls
# `driver.evalTopLevelForm` (D-374), which recurses through
# `topLevelDoChildren`; `eval_session.evalSource` analysed the whole form
# instead, so the nREPL and REPL paths analysed a use site before the
# `require` beside it had run:
#
#   (do (require '[clojure.string :as s]) (s/upper-case "ok"))
#   -e     -> "OK"
#   nrepl  -> Name error: No namespace: 's'
#
# That is the shape an editor sends when the user evaluates a region, so
# the failure lands on the primary tooling surface while the CLI looks
# fine. JVM Clojure evaluates a top-level `do` subform by subform for the
# same reason.
#
# Same harness shape as phase14_nrepl_classpath.sh.

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

mkdir -p "$WORK/src/cljw_do_probe"
cat > "$WORK/src/cljw_do_probe/lib.clj" <<'EOF'
(ns cljw-do-probe.lib)
(defn answer [] 42)
EOF
cat > "$WORK/deps.edn" <<'EOF'
{:paths ["src"]}
EOF

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
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
}

PORT=$((17300 + RANDOM % 400))

# 1. A bundled namespace required and used inside one top-level `do`.
start_server "$PORT" -cp src
got=$(drive "$PORT" '(do (require (quote [clojure.string :as s])) (s/upper-case "ok"))')
[[ "$got" == '"OK"' ]] || fail "nrepl_do_bundled_require -> $got"
echo "PASS nrepl_do_bundled_require -> $got"

# 2. Same shape against a namespace off the filesystem classpath, which is
#    what an editor actually sends when evaluating a project region.
got=$(drive "$PORT" '(do (require (quote [cljw-do-probe.lib :as l])) (l/answer))')
[[ "$got" == "42" ]] || fail "nrepl_do_project_require -> $got"
echo "PASS nrepl_do_project_require -> $got"

# 3. Nested `do`, since the unroll recurses.
got=$(drive "$PORT" '(do (do (require (quote [clojure.set :as st]))) (st/union #{1} #{2}))')
[[ "$got" == "#{1 2}" || "$got" == "#{2 1}" ]] || fail "nrepl_nested_do -> $got"
echo "PASS nrepl_nested_do -> $got"

# 4. A `do` whose value is the LAST subform, not the first, and whose
#    earlier subforms still take effect.
got=$(drive "$PORT" '(do (def a 1) (def b 2) (+ a b))')
[[ "$got" == "3" ]] || fail "nrepl_do_returns_last -> $got"
echo "PASS nrepl_do_returns_last -> $got"
stop_server

# 5. The `-e` path must keep working, since it is the one that was already
#    correct and the fix moves the shared code underneath it.
got=$("$BIN" -e '(do (require (quote [clojure.string :as s])) (s/upper-case "ok"))' 2>&1 | tail -1)
[[ "$got" == '"OK"' ]] || fail "e_flag_do_still_works -> $got"
echo "PASS e_flag_do_still_works -> $got"

echo "phase14_nrepl_toplevel_do: 5/5"
