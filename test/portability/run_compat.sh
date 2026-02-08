#!/bin/bash
# Run portability tests on both CW and JVM Clojure, compare output.
# Usage: bash test/portability/run_compat.sh

set -e

CLJW=${CLJW:-./zig-out/bin/cljw}
CLJ=${CLJ:-clj}
PASS=0
FAIL=0

for test_file in test/portability/*_compat.clj; do
    name=$(basename "$test_file" .clj)
    echo -n "Testing $name... "

    cw_out=$($CLJW "$test_file" 2>&1 | grep -v "^nil$")
    jvm_out=$($CLJ -M "$test_file" 2>&1)

    diff_out=$(diff <(echo "$cw_out") <(echo "$jvm_out") || true)

    if [ -z "$diff_out" ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "$diff_out"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
