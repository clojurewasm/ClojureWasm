#!/usr/bin/env bash
# test/e2e/phase14_nrepl_completion.sh
#
# CIDER completion parity (user-directed 2026-07-15, e2e-first): replay
# the mainline-captured fixtures (test/e2e/fixtures/completion/ — see
# scripts/completion_oracle.py) against cljw's nREPL `completions` op,
# with NO JVM needed at gate time. Per-group policy:
#   - exact groups: cljw's normalized reply == the mainline fixture
#     (vars incl. dash-fuzzy `ma-i` + `tru` special-form/literal, user
#     ns, stdlib ns/alias, negatives).
#   - subset groups: every cljw candidate must exist in the fixture AND
#     a curated MUST list must be present — where mainline's extras are
#     its classpath leak (classes — AD-054), its environment-interned
#     keywords, vars cljw does not carry (definline/defstruct/…, the
#     D-562 parity-inventory arc), or Character/TYPE
#     (designed skip + D-561).
#   - every reply must be by-name sorted (the built-in's sort-by).
#
# Refresh the fixtures with `python3 scripts/completion_oracle.py
# --capture` (spawns a real JVM nREPL + cider-nrepl); the parity gap
# audit is `--diff`.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

PORT=$(( 20000 + (RANDOM % 1000) ))
"$BIN" nrepl --port "$PORT" > /tmp/cljw_nreplc_stdout.$$ 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; rm -f /tmp/cljw_nreplc_stdout.$$' EXIT

python3 - "$PORT" <<'PY' || { echo "FAIL phase14_nrepl_completion" >&2; exit 1; }
import json, os, sys, time
sys.path.insert(0, "scripts")
from nrepl_bencode import NreplClient

port = int(sys.argv[1])
with open("test/e2e/fixtures/completion/requests.json") as f:
    groups = json.load(f)
with open("test/e2e/fixtures/completion/expected.json") as f:
    expected = json.load(f)

# Curated MUST lists for the subset groups (candidates that MUST appear,
# with the fixture's exact type/ns) and MUST-NOT names (mainline
# classpath leak cljw deliberately never fakes).
MUST = {
    "classes|Character": ["Character", "java.lang.Character"],
    "classes|Big": ["BigDecimal", "BigInteger", "java.math.BigDecimal", "java.math.BigInteger"],
    "core_vars|def": ["def", "definterface", "defmethod", "defmulti", "defn",
                       "defn-", "defonce", "defprotocol", "defrecord", "deftype"],
    "keywords|:req": [":req", ":req-un", ":require"],
    "static_members|Character/": ["Character/BYTES", "Character/MIN_RADIX",
                                   "Character/isDigit", "Character/toUpperCase",
                                   "Character/isEmoji", "Character/isJavaLetter",
                                   "Character/DIRECTIONALITY_UNDEFINED"],
}
MUST_NOT = {
    "classes|Character": ["java.lang.CharacterData00", "java.lang.CharacterData"],
    "static_members|Character/": ["Character/TYPE"],
}
SUBSET_GROUPS = set(MUST) | set(MUST_NOT)

def normalize(cands):
    out = []
    for c in cands or []:
        d = {"candidate": c.get("candidate"), "type": c.get("type")}
        if "ns" in c:
            d["ns"] = c["ns"]
        out.append(d)
    return sorted(out, key=lambda d: d["candidate"] or "")

fails = 0
for g in groups:
    cl = NreplClient("127.0.0.1", port)
    cl.clone()
    for code in g.get("setup", []):
        cl.request({"op": "eval", "code": code})
    for p in g["probes"]:
        key = f'{g["group"]}|{p["prefix"]}'
        res = cl.request({"op": "completions", "prefix": p["prefix"], "ns": p.get("ns", "user")})
        raw = next((r.get("completions") for r in res if isinstance(r, dict) and "completions" in r), None)
        got = normalize(raw)
        names = [c["candidate"] for c in got]
        exp = expected.get(key, [])
        # sortedness: the server must reply by-name sorted (normalize()
        # sorts, so compare against the RAW order).
        raw_names = [c.get("candidate") for c in raw or []]
        if raw_names != sorted(raw_names):
            print(f"FAIL {key}: reply not by-name sorted: {raw_names[:8]}…"); fails += 1; continue
        if key in SUBSET_GROUPS:
            exp_by_name = {c["candidate"]: c for c in exp}
            extras = [c for c in got if c["candidate"] not in exp_by_name]
            if extras:
                print(f"FAIL {key}: cljw offers candidates mainline does not: {extras}"); fails += 1; continue
            missing = [m for m in MUST.get(key, []) if m not in names]
            if missing:
                print(f"FAIL {key}: MUST candidates absent: {missing}"); fails += 1; continue
            bad_meta = [c for c in got if c != exp_by_name[c["candidate"]]]
            if bad_meta:
                print(f"FAIL {key}: type/ns mismatch vs fixture: {bad_meta}"); fails += 1; continue
            leaked = [m for m in MUST_NOT.get(key, []) if m in names]
            if leaked:
                print(f"FAIL {key}: MUST-NOT candidates leaked: {leaked}"); fails += 1; continue
            print(f"PASS {key} (subset: {len(got)} ⊆ {len(exp)})")
        else:
            if got != exp:
                mset = {json.dumps(d, sort_keys=True) for d in exp}
                cset = {json.dumps(d, sort_keys=True) for d in got}
                print(f"FAIL {key}: mainline {len(exp)} vs cljw {len(got)}")
                for line in sorted(mset - cset)[:6]: print(f"   -mainline-only {line}")
                for line in sorted(cset - mset)[:6]: print(f"   +cljw-only     {line}")
                fails += 1; continue
            print(f"PASS {key} (exact: {len(got)})")
    cl.close()

sys.exit(1 if fails else 0)
PY

echo "ALL PASS phase14_nrepl_completion"
