#!/usr/bin/env bash
# test/e2e/phase14_namespaced_maps.sh — namespaced map literals #:ns{…} (D-219).
# Reader: #:foo{:a 1} → {:foo/a 1}; #::{…} current-ns; #::alias{…} alias-resolved;
# :_/x strips the namespace; already-qualified keys keep their own ns.
# Printer: *print-namespace-maps* true (default) → compact #:ns{…} when all keys
# share one namespace (array_map). Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# reader: key qualification
assert_eq 'read_basic'  "$("$BIN" -e '(= #:foo{:a 1 :b 2} {:foo/a 1 :foo/b 2})')" 'true'
assert_eq 'read_keep'   "$("$BIN" -e '(= #:foo{:a 1 :x/c 3} {:foo/a 1 :x/c 3})')" 'true'
assert_eq 'read_strip'  "$("$BIN" -e '(= #:foo{:_/d 4} {:d 4})')"                  'true'
assert_eq 'read_lookup' "$("$BIN" -e '(:foo/a #:foo{:a 1})')"                      '1'
assert_eq 'read_current' "$("$BIN" -e '(= #::{:a 1} {:user/a 1})')"                'true'
# alias-resolved (#::alias) — require + use must be SEPARATE top-level forms
# (the alias is resolved at analyze time, the require runs at eval time), so
# read the last printed line (the require form prints its own nil first).
assert_eq 'read_alias'  "$("$BIN" -e '(require (quote [clojure.string :as s])) (= (set (keys #::s{:a 1})) #{:clojure.string/a})' 2>&1 | tail -1)" 'true'

# printer: compact #:ns{…} (default *print-namespace-maps* true)
assert_eq 'print_compact' "$("$BIN" -e '(pr-str #:foo{:a 1 :b 2})')"    '"#:foo{:a 1, :b 2}"'
assert_eq 'print_fromqual' "$("$BIN" -e '(pr-str {:foo/a 1 :foo/b 2})')" '"#:foo{:a 1, :b 2}"'
assert_eq 'print_plain'   "$("$BIN" -e '(pr-str {:a 1 :b 2})')"          '"{:a 1, :b 2}"'
assert_eq 'print_mixed'   "$("$BIN" -e '(pr-str {:foo/a 1 :bar/b 2})')"  '"{:foo/a 1, :bar/b 2}"'
assert_eq 'print_str'     "$("$BIN" -e '(str #:foo{:a 1})')"             '"#:foo{:a 1}"'
assert_eq 'print_dotted'  "$("$BIN" -e '(pr-str #:a.b.c{:x 1})')"        '"#:a.b.c{:x 1}"'
# nested namespaced map round-trips
assert_eq 'print_nested'  "$("$BIN" -e '(pr-str #:foo{:a #:bar{:x 1}})')" '"#:foo{:a #:bar{:x 1}}"'

# D-221: read-string resolves ::auto-keywords against the current ns.
assert_eq 'rs_autokw'  "$("$BIN" -e '(namespace (read-string "::foo"))')"       '"user"'
assert_eq 'rs_ns_cur'  "$("$BIN" -e '(= (read-string "#::{:a 1}") {:user/a 1})')" 'true'

echo "OK — phase14_namespaced_maps (15 cases) green"
