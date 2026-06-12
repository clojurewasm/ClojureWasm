#!/usr/bin/env bash
# test/e2e/phase14_uri.sh
#
# java.net.URI (minimal host_instance surface) + java.net.URLEncoder/encode
# static method. Landed to unblock hiccup (extend-protocol ToString/ToURI on
# java.net.URI + url-encode). Scope = scheme/host/path extraction the
# hiccup.util protocols need, NOT full RFC 3986 (see runtime/net/uri.zig).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

# --- getHost / getPath on an absolute hierarchical URI (cljw -e prints strings
# --- with pr-str quotes) ---
assert_eq 'host_abs'  "$(run '(.getHost (java.net.URI. "http://example.com/x"))')" '"example.com"'
assert_eq 'path_abs'  "$(run '(.getPath (java.net.URI. "http://example.com/x"))')" '"/x"'
# port + userinfo stripped from the authority
assert_eq 'host_port' "$(run '(.getHost (java.net.URI. "http://u@example.com:8080/p"))')" '"example.com"'

# --- relative reference: no authority -> getHost nil, whole string is path ---
assert_eq 'host_rel'  "$(run '(nil? (.getHost (java.net.URI. "/relative")))')" 'true'
assert_eq 'path_rel'  "$(run '(.getPath (java.net.URI. "/relative"))')" '"/relative"'
assert_eq 'path_bare' "$(run '(.getPath (java.net.URI. "products"))')" '"products"'

# --- toString returns the original string ---
assert_eq 'tostr'     "$(run '(str (java.net.URI. "http://a/b"))')" '"http://a/b"'

# --- class / instance? ---
assert_eq 'class'        "$(run '(class (java.net.URI. "http://a"))')" 'java.net.URI'
assert_eq 'instance_pos' "$(run '(instance? java.net.URI (java.net.URI. "http://a"))')" 'true'
assert_eq 'instance_neg' "$(run '(instance? java.net.URI 5)')" 'false'

# --- extend-protocol dispatches on the concrete java.net.URI type ---
assert_eq 'extend_proto' "$(run '(do (defprotocol Showable (sh [x])) (extend-protocol Showable java.net.URI (sh [u] (str "URI:" (.getHost u)))) (sh (java.net.URI. "http://h/p")))')" '"URI:h"'

# --- URLEncoder/encode (application/x-www-form-urlencoded) ---
assert_eq 'urlenc_space' "$(run '(java.net.URLEncoder/encode "a b" "UTF-8")')" '"a+b"'
assert_eq 'urlenc_amp'   "$(run '(java.net.URLEncoder/encode "a&c" "UTF-8")')" '"a%26c"'
assert_eq 'urlenc_safe'  "$(run '(java.net.URLEncoder/encode "a-b_c.d*e" "UTF-8")')" '"a-b_c.d*e"'
