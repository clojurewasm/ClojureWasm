#!/usr/bin/env bash
# test/e2e/bulk_literal.sh
#
# D-346: evaluating a very large collection literal must never exhaust the VM
# operand stack. A literal of constants is one constant (the analyzer folds
# it, as clj's ConstantExpr does); a literal with evaluated elements is built
# in bounded steps, so the operand stack holds at most one step. A form that
# still exceeds a limit of the bytecode format raises a catchable exception,
# never exit 70. JVM clj rejects every 40k literal below with a catchable
# CompilerException ("Method code too large!"), where cljw builds them.
#
# The generated sources live in the job's temporary directory. Cases 1-2 run
# through `--compare`, so TreeWalk and the VM must agree on every line.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cljw-bulk-literal.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
n = 40000
ints = ' '.join(str(i) for i in range(n))
pairs = ' '.join(f'{i} {i + 1}' for i in range(n))
xs = 'x ' * n
# Evaluated elements on both sides of the 512-element build steps.
mixed_set = ' '.join('x' if i == 511 else str(i) for i in range(n))
dyn_map = ' '.join(f'{i} x' for i in range(n))
(p / 'large.clj').write_text(f'''
(let [v [{ints}] m {{{pairs}}} s #{{{ints}}}]
  (prn [(count v) (nth v 39999) (count m) (get m 39999) (count s) (contains? s 39999)]))
(let [x 7 v [{xs}]] (prn [(count v) (nth v 0) (nth v 39999) (apply = v)]))
(let [x 7 m {{{dyn_map}}}] (prn [(count m) (get m 0) (get m 39999)]))
(let [x 50000 s #{{{mixed_set}}}] (prn [(count s) (contains? s x) (contains? s 511)]))
(let [x 9] (prn (nth [0 [{xs}] x] 2)))
(let [x 1] (prn (count (get {{:v [{xs}] :k x}} :v))))
(let [x 1] (prn (count (first #{{[{xs}]}}))))
(prn (count (:v {{:v [{ints}] :m {{{pairs}}}}})))
:done
''')
(p / 'eval.clj').write_text('''
(defn ints [n] (apply str (interpose " " (range n))))
(defn kvs [f] (apply str (interpose " " (map f (range 40000)))))
(prn (count (eval (read-string (str "[" (ints 40000) "]")))))
(prn (get (eval (read-string (str "{" (kvs #(str % " " (inc %))) "}"))) 39999))
(prn (count (eval (read-string (str "#{" (ints 40000) "}")))))
(prn (count ((eval (read-string (str "(fn [x] [" (apply str (repeat 40000 "x ")) "])"))) 1)))
(prn (count ((eval (read-string (str "(fn [x] {" (kvs #(str % " x")) "})"))) 1)))
(prn (count ((eval (read-string (str "(fn [x] #{x " (ints 39999) "})"))) -1)))
(prn (count (first (eval (read-string (str "[[" (ints 40000) "]]"))))))
(prn (count (:v ((eval (read-string (str "(fn [x] {:v [" (apply str (repeat 40000 "x ")) "] :s #{x}})"))) 1))))
(prn (count (first ((eval (read-string (str "(fn [x] #{{:m {" (kvs #(str % " x")) "}}})"))) 1))))
:done
''')
# More distinct constants in one form than a compiled chunk can index.
(p / 'pool.clj').write_text('(let [x 1] [x ' + ' '.join(str(i) for i in range(70000)) + '])\n')
(p / 'pool_catch.clj').write_text(
    '(prn (try (eval (read-string (slurp "' + str(p / 'pool.clj') + '"))) (catch Exception e :caught)))\n')
# A branch longer than a jump offset reaches.
(p / 'branch_catch.clj').write_text(
    '(prn (try (eval (read-string (str "(let [x 1] (if x [" (apply str (repeat 40000 "x ")) "] 0))")))'
    ' (catch Exception e :caught)))\n')
# A call with more arguments than the operand stack holds.
(p / 'args_catch.clj').write_text(
    '(prn (try (eval (read-string (str "(let [x 1] (+ " (apply str (repeat 20000 "x ")) "))")))'
    ' (catch StackOverflowError e :so)))\n')
# AOT: folded hash-map and large-set constants, a folded 40k vector, and
# stepped vector, map and set builds.
(p / 'app.clj').write_text(f'''
(def big {{:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10}})
(def many #{{:a :b :c :d :e :f :g :h :i :j}})
(defn build [x] [{xs}])
(defn build-m [x] {{{dyn_map}}})
(defn build-s [x] #{{x {ints}}})
(prn [(count big) (:j big) (count many) (count [{ints}]) (count (build 2)) (nth (build 2) 39999)
      (count (build-m 2)) (get (build-m 2) 39999) (count (build-s -1)) (contains? (build-s -1) -1)])
''')
PY

expect_compare() {
    local name="$1" file="$2" want="$3" got
    got=$("$BIN" --compare "$file" 2>&1) || fail "$name: --compare exited non-zero: $(head -c 400 <<< "$got")"
    [[ "$got" == "$want" ]] || fail "$name: got $(head -c 400 <<< "$got")"
    echo "PASS $name"
}

# 1: constant and evaluated 40k literals, nested, on both backends.
expect_compare large "$TMP/large.clj" '[40000 39999 40000 40000 40000 true]
[40000 7 7 true]
[40000 7 7]
[40000 true false]
9
40000
40000
40000
OK :done'

# 2: the read-string / eval path, constant, evaluated and nested, on both backends.
expect_compare eval "$TMP/eval.clj" '40000
40000
40000
40000
40000
40000
40000
40000
1
OK :done'

# 3: past the constant-pool limit the VM raises a catchable exception.
got=$("$BIN" "$TMP/pool_catch.clj" 2>&1) || fail "pool_catch: exited non-zero: $got"
[[ "$(tail -1 <<< "$got")" == ':caught' ]] || fail "pool_catch: got $got"
set +e
out=$("$BIN" "$TMP/pool.clj" 2>&1); code=$?
set -e
(( code != 0 && code != 70 )) || fail "pool: exit $code, want a catalog error, not 0 or 70: $out"
grep -q 'too large' <<< "$out" || fail "pool: message: $out"
echo "PASS constant_pool_limit_catchable"

# 4: so is a branch longer than a jump offset reaches.
got=$("$BIN" "$TMP/branch_catch.clj" 2>&1) || fail "branch_catch: exited non-zero: $got"
[[ "$(tail -1 <<< "$got")" == ':caught' ]] || fail "branch_catch: got $got"
echo "PASS jump_limit_catchable"

# 5: an operand-stack overflow is a catchable StackOverflowError.
got=$("$BIN" "$TMP/args_catch.clj" 2>&1) || fail "args_catch: exited non-zero: $got"
[[ "$(tail -1 <<< "$got")" == ':so' ]] || fail "args_catch: got $got"
echo "PASS operand_stack_overflow_catchable"

# 6: the reader still rejects duplicate literal keys (ADR-0200).
for literal in '{1 2 1 3}' '#{1 1}'; do
    printf '%s\n' "$literal" > "$TMP/duplicate.clj"
    if "$BIN" "$TMP/duplicate.clj" > "$TMP/dup.out" 2>&1; then
        fail "accepted duplicate: $literal"
    fi
    grep -q 'Duplicate key' "$TMP/dup.out" || fail "duplicate message: $(cat "$TMP/dup.out")"
done
echo "PASS duplicate_literal_keys"

# 7: `cljw build` serializes the folded constants (bytecode format v12) and
# the stepped builds.
"$BIN" build "$TMP/app.clj" -o "$TMP/app" >/dev/null
got=$("$TMP/app" 2>&1) || fail "aot: exited non-zero: $got"
[[ "$got" == '[10 10 10 40000 40000 2 40000 2 40001 true]' ]] || fail "aot: got $got"
echo "PASS aot_build"

echo "PASS D-346 bulk vector/map/set literals"
