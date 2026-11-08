#!/usr/bin/env bash
# `cljw.net/connect-unix` + `cljw.net/listen-unix` — the UNIX-domain pair.
#
# `UnixAddress.listen` / `.connect` answer the SAME `Server` / `Stream` types the
# IpAddress pair does, so this reuses both carriers, both descriptors, both
# method tables and both finalisers: a unix socket is a different ADDRESS, not a
# different representation. `.accept` / `.read` / `.write` / `.close` are the
# same functions the TCP side uses.
#
# Why it exists: a unix socket needs no port to allocate or collide on, and the
# filesystem already answers who may connect — which is why hive-universe's
# JSON-RPC endpoint uses one. Without this a cljw client could not reach it.
#
# Two behaviours here are deliberate and pinned because they look like bugs:
# `.port` on a unix server is 0, and a leftover socket file is NOT unlinked.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$PWD/zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

# Socket paths are capped at 108 BYTES by the OS, so the scratch dir has to be
# short — a default TMPDIR under a long home would fail the bind, not the test.
WORK=$(mktemp -d /tmp/cljwnetXXXX)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# Bytes cross a unix socket, using the same methods the TCP side uses. As with
# the TCP e2e this runs in ONE process: connect completes into the kernel accept
# queue, so accept cannot deadlock a single-threaded runtime.
SOCK="$WORK/rt.sock"
cat > "$WORK/roundtrip.cljw" <<EOF
(let [srv (cljw.net/listen-unix "$SOCK")
      cli (cljw.net/connect-unix "$SOCK")
      s   (.accept srv)
      out (byte-array 3)]
  (aset out 0 (byte 104))   ; h
  (aset out 1 (byte 105))   ; i
  (aset out 2 (byte 33))    ; !
  (.write cli out 3)
  (let [buf (byte-array 16)
        n   (.read s buf)]
    (prn [n (apply str (map char (take n (seq buf))))]))
  (.close cli) (.close s) (.close srv))
EOF
got=$("$BIN" "$WORK/roundtrip.cljw" 2>/dev/null)
assert_eq 'unix_round_trip' "$got" '[3 "hi!"]'

# An accepted unix socket is the same kind of thing connect-unix returns AND the
# same kind the TCP side returns. If these ever diverge, every reader has to
# learn which of three things it is holding.
SOCK2="$WORK/same.sock"
cat > "$WORK/same.cljw" <<EOF
(let [srv (cljw.net/listen-unix "$SOCK2")
      cli (cljw.net/connect-unix "$SOCK2")
      s   (.accept srv)
      tcp-srv (cljw.net/listen "127.0.0.1" 0)
      tcp-cli (cljw.net/connect "127.0.0.1" (.port tcp-srv))]
  (prn [(= (str (class s)) (str (class cli)))
        (= (str (class cli)) (str (class tcp-cli)))
        (= (str (class srv)) (str (class tcp-srv)))])
  (.close cli) (.close s) (.close srv) (.close tcp-cli) (.close tcp-srv))
EOF
got=$("$BIN" "$WORK/same.cljw" 2>/dev/null)
assert_eq 'unix_and_tcp_share_representations' "$got" '[true true true]'

# `.port` on a unix server is 0. A unix socket has no port, so 0 is the honest
# answer rather than a fabricated one — pinned so nobody "fixes" it later.
SOCK3="$WORK/port.sock"
cat > "$WORK/port.cljw" <<EOF
(let [srv (cljw.net/listen-unix "$SOCK3")]
  (prn (.port srv))
  (.close srv))
EOF
got=$("$BIN" "$WORK/port.cljw" 2>/dev/null)
assert_eq 'unix_server_has_no_port' "$got" '0'

# A leftover socket file is NOT unlinked for you. The path may still belong to a
# LIVE server, and deleting another process's socket is the caller's decision.
SOCK4="$WORK/stale.sock"
touch "$SOCK4"
cat > "$WORK/stale.cljw" <<EOF
(prn (try (do (cljw.net/listen-unix "$SOCK4") :bound)
          (catch Exception _ :refused)))
EOF
got=$("$BIN" "$WORK/stale.cljw" 2>/dev/null)
assert_eq 'stale_path_is_not_silently_removed' "$got" ':refused'

# The 108-byte cap is the OS's, and it is easy to exceed by accident, so it is
# reported as a clear argument error rather than a bind failure.
LONG=$(printf 'x%.0s' $(seq 1 200))
cat > "$WORK/long.cljw" <<EOF
(prn (try (do (cljw.net/connect-unix "/tmp/$LONG.sock") :ok)
          (catch Exception _ :rejected)))
EOF
got=$("$BIN" "$WORK/long.cljw" 2>/dev/null)
assert_eq 'over_long_path_is_rejected' "$got" ':rejected'

echo
echo "cljw.net unix-domain e2e: all green."
