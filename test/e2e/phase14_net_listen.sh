#!/usr/bin/env bash
# `cljw.net/listen` — the server side of cljw.net.
#
# Until now cljw.net exposed only `connect`, so a cljw process could dial out
# and never answer. The `.listen`/`.accept` pair it needs has been in
# src/app/nrepl.zig the whole time (cljw runs an nREPL server); this lifts it to
# a Clojure-facing surface.
#
# `.accept` answers a socket built on the SAME descriptor `connect` produces, so
# `.read` / `.write` / `.close` need no new arm — a new PRODUCER of an existing
# representation rather than a second representation.
#
# The round trip runs in ONE process on purpose. `connect` completes against the
# kernel's accept queue, so the connection is already pending when `.accept` is
# called and a single-threaded runtime does not deadlock on itself.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# Port 0 asks the OS for an ephemeral port; `.port` is the only way to learn
# which one it got, and therefore the only way port 0 is usable at all.
got=$("$BIN" - <<'EOF' 2>/dev/null
(let [srv (cljw.net/listen "127.0.0.1" 0)
      p   (.port srv)]
  (prn [(> p 0) (<= p 65535)])
  (.close srv))
EOF
)
assert_eq 'ephemeral_port_is_reported' "$got" '[true true]'

# The whole point: bytes cross from a client to an accepted server socket.
got=$("$BIN" - <<'EOF' 2>/dev/null
(let [srv  (cljw.net/listen "127.0.0.1" 0)
      port (.port srv)
      cli  (cljw.net/connect "127.0.0.1" port)
      s    (.accept srv)
      out  (byte-array 3)]
  (aset out 0 (byte 104))   ; h
  (aset out 1 (byte 105))   ; i
  (aset out 2 (byte 33))    ; !
  (.write cli out 3)
  (let [buf (byte-array 16)
        n   (.read s buf)]
    (prn [n (apply str (map char (take n (seq buf))))]))
  (.close cli) (.close s) (.close srv))
EOF
)
assert_eq 'client_to_accepted_socket' "$got" '[3 "hi!"]'

# An accepted socket is the same kind of thing connect returns, so it answers
# the same methods. If this ever diverges, the two are separate representations
# and every reader has to learn which one it holds.
got=$("$BIN" - <<'EOF' 2>/dev/null
(let [srv  (cljw.net/listen "127.0.0.1" 0)
      cli  (cljw.net/connect "127.0.0.1" (.port srv))
      s    (.accept srv)]
  (prn (= (str (class s)) (str (class cli))))
  (.close cli) (.close s) (.close srv))
EOF
)
assert_eq 'accepted_socket_is_a_cljw_net_socket' "$got" 'true'

# Closing is idempotent, and closing the LISTENER does not close the sockets it
# already handed out — the door, not the guests.
got=$("$BIN" - <<'EOF' 2>/dev/null
(let [srv  (cljw.net/listen "127.0.0.1" 0)
      cli  (cljw.net/connect "127.0.0.1" (.port srv))
      s    (.accept srv)
      out  (byte-array 1)]
  (.close srv)
  (.close srv)                       ; idempotent
  (aset out 0 (byte 122))            ; z
  (.write cli out 1)
  (let [buf (byte-array 4)
        n   (.read s buf)]
    (prn [n (char (aget buf 0))]))
  (.close cli) (.close s))
EOF
)
assert_eq 'close_is_idempotent_and_spares_accepted' "$got" '[1 \z]'

# A hostname is not a listen address: you bind an interface you already own,
# so there is nothing to resolve and a name is a caller mistake, not a lookup.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (cljw.net/listen "not-an-ip" 0) :no-throw
          (catch Exception _ :threw)))
EOF
)
assert_eq 'hostname_is_rejected' "$got" ':threw'

echo
echo "cljw.net/listen e2e: all green."
