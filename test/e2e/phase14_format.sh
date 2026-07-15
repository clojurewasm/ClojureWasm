#!/usr/bin/env bash
# test/e2e/phase14_format.sh — format (clojure.core/format, D-134). printf
# subset %[-][width][.prec]CONV where CONV ∈ {s,d,f,x} + no-arg %% / %n.
# %f defaults to 6 fractional digits; width space-pads (- left-justifies).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# conversions
assert_eq 'plain'   "$("$BIN" -e '(format "hello")')"            '"hello"'
assert_eq 'd'       "$("$BIN" -e '(format "%d items" 3)')"       '"3 items"'
assert_eq 'sd'      "$("$BIN" -e '(format "%s = %d" "x" 42)')"   '"x = 42"'
assert_eq 'f6'      "$("$BIN" -e '(format "%f" 1.5)')"           '"1.500000"'
assert_eq 'fprec'   "$("$BIN" -e '(format "%.2f" 3.14159)')"     '"3.14"'
assert_eq 'f0'      "$("$BIN" -e '(format "%.0f" 3.7)')"         '"4"'
assert_eq 'hex'     "$("$BIN" -e '(format "%x" 255)')"           '"ff"'
assert_eq 'pct'     "$("$BIN" -e '(format "100%%")')"            '"100%"'
assert_eq 'kw'      "$("$BIN" -e '(format "%s/%s" :a :b)')"      '":a/:b"'
assert_eq 'multi'   "$("$BIN" -e '(format "%d-%d-%d" 1 2 3)')"   '"1-2-3"'
# width / flags
assert_eq 'w_d'     "$("$BIN" -e '(format "[%5d]" 3)')"          '"[    3]"'
assert_eq 'w_left'  "$("$BIN" -e '(format "[%-5d]" 3)')"         '"[3    ]"'
assert_eq 'w_s'     "$("$BIN" -e '(format "[%10s]" "hi")')"      '"[        hi]"'
assert_eq 'w_sl'    "$("$BIN" -e '(format "[%-10s]" "hi")')"     '"[hi        ]"'
assert_eq 'w_f'     "$("$BIN" -e '(format "[%8.2f]" 3.14159)')"  '"[    3.14]"'
# zero-pad flag (clj-verified): sign stays leftmost, `-` overrides `0`
assert_eq 'w_zero'  "$("$BIN" -e '(format "%05d" 42)')"          '"00042"'
assert_eq 'w_zneg'  "$("$BIN" -e '(format "%05d" -42)')"         '"-0042"'
assert_eq 'w_zleft' "$("$BIN" -e '(format "[%-05d]" 42)')"       '"[42   ]"'
assert_eq 'w_zhex'  "$("$BIN" -e '(format "%04x" 255)')"         '"00ff"'
assert_eq 'w_over'  "$("$BIN" -e '(format "[%3d]" 12345)')"      '"[12345]"'
# newline directive (count + split prove a real \n)
assert_eq 'newline' "$("$BIN" -e '(count (format "x%ny"))')"     '3'
assert_eq 'nl_mid'  "$("$BIN" -e '(vec (clojure.string/split (format "x%ny") #"\n"))')" '["x" "y"]'
# integer conversions X / o + sign flags (+, space, parens) + grouping (clj sweep)
assert_eq 'Xhex'    "$("$BIN" -e '(format "%X" 255)')"           '"FF"'
assert_eq 'octal'   "$("$BIN" -e '(format "%o" 8)')"             '"10"'
assert_eq 'signplus' "$("$BIN" -e '(format "%+d" 42)')"          '"+42"'
assert_eq 'signspace' "$("$BIN" -e '(format "% d" 42)')"         '" 42"'
assert_eq 'parens'  "$("$BIN" -e '(format "%(d" -5)')"           '"(5)"'
assert_eq 'grouping' "$("$BIN" -e '(format "%,d" 1000000)')"     '"1,000,000"'
assert_eq 'groupneg' "$("$BIN" -e '(format "%,d" -1234567)')"    '"-1,234,567"'
assert_eq 'plus_zero' "$("$BIN" -e '(format "%+05d" 42)')"       '"+0042"'
assert_eq 'group_zero' "$("$BIN" -e '(format "%,012d" 1000)')"   '"00000001,000"'
# scientific %e / %E (default precision 6; exponent is sign + >=2 digits)
assert_eq 'sci_e'    "$("$BIN" -e '(format "%e" 12345.678)')"     '"1.234568e+04"'
assert_eq 'sci_eprec' "$("$BIN" -e '(format "%.2e" 12345.678)')" '"1.23e+04"'
assert_eq 'sci_E'    "$("$BIN" -e '(format "%E" 12345.678)')"     '"1.234568E+04"'
assert_eq 'sci_neg'  "$("$BIN" -e '(format "%e" -5.5)')"          '"-5.500000e+00"'
assert_eq 'sci_small' "$("$BIN" -e '(format "%e" 0.000123)')"     '"1.230000e-04"'
assert_eq 'sci_zero' "$("$BIN" -e '(format "%e" 0.0)')"           '"0.000000e+00"'
assert_eq 'sci_one'  "$("$BIN" -e '(format "%e" 1.0)')"           '"1.000000e+00"'
# general %g / %G (P sig figs; fixed when -4<=exp<P else scientific; keeps zeros)
assert_eq 'gen_g'    "$("$BIN" -e '(format "%g" 0.0001234)')"     '"0.000123400"'
assert_eq 'gen_int'  "$("$BIN" -e '(format "%g" 123456.0)')"      '"123456"'
assert_eq 'gen_sci'  "$("$BIN" -e '(format "%g" 1234567.0)')"     '"1.23457e+06"'
assert_eq 'gen_zero' "$("$BIN" -e '(format "%g" 0.0)')"           '"0.00000"'
assert_eq 'gen_prec' "$("$BIN" -e '(format "%.3g" 123456.0)')"    '"1.23e+05"'
assert_eq 'gen_small' "$("$BIN" -e '(format "%g" 0.00001)')"      '"1.00000e-05"'
assert_eq 'gen_G'    "$("$BIN" -e '(format "%G" 1234567.0)')"     '"1.23457E+06"'
assert_eq 'gen_neg'  "$("$BIN" -e '(format "%g" -42.5)')"         '"-42.5000"'
# --- D-216: completed flag/conversion surface (clj-parity) ---
# heap-Long operands (D-165) on %d/%x; unsigned-64 %x/%X/%o; # alternate form
assert_eq 'd_heaplong' "$("$BIN" -e '(format "%d" 1000000000000000)')"  '"1000000000000000"'
assert_eq 'd_grp_long' "$("$BIN" -e '(format "%,d" 1000000000000000)')" '"1,000,000,000,000,000"'
assert_eq 'x_neg_u64'  "$("$BIN" -e '(format "%x" -1)')"                '"ffffffffffffffff"'
assert_eq 'x_alt'      "$("$BIN" -e '(format "%#x" 255)')"              '"0xff"'
assert_eq 'X_alt'      "$("$BIN" -e '(format "%#X" 255)')"              '"0XFF"'
assert_eq 'o_alt'      "$("$BIN" -e '(format "%#o" 64)')"               '"0100"'
# float sign / group flags
assert_eq 'f_plus'     "$("$BIN" -e '(format "%+.2f" 3.14)')"           '"+3.14"'
assert_eq 'f_space'    "$("$BIN" -e '(format "% .2f" 3.14)')"           '" 3.14"'
assert_eq 'f_paren'    "$("$BIN" -e '(format "%(.2f" -3.14)')"          '"(3.14)"'
assert_eq 'f_group'    "$("$BIN" -e '(format "%,.2f" 1234567.5)')"      '"1,234,567.50"'
assert_eq 'e_plus'     "$("$BIN" -e '(format "%+e" 1234.5)')"           '"+1.234500e+03"'
# %s nil → "null"; %S upper; %.Ns truncate
assert_eq 's_nil'      "$("$BIN" -e '(format "%s" nil)')"               '"null"'
assert_eq 'S_upper'    "$("$BIN" -e '(format "%S" "hi")')"              '"HI"'
assert_eq 's_prec'     "$("$BIN" -e '(format "%.3s" "hello")')"         '"hel"'
assert_eq 's_prec_w'   "$("$BIN" -e '(format "%8.3s|" "hello")')"       '"     hel|"'
# %h/%H: hex of the single-system hasheq (AD-009): hex((hash "abc")) =
# hex(74834163) — clj's %h renders Java String.hashCode ("17862") instead.
assert_eq 'h_hex'      "$("$BIN" -e '(format "%h" "abc")')"             '"475e0f3"'
assert_eq 'H_hex'      "$("$BIN" -e '(format "%H" "abc")')"             '"475E0F3"'
assert_eq 'h_nil'      "$("$BIN" -e '(format "%h" nil)')"               '"null"'

# %t date/time family (D-470). AD-052 pins: UTC + English names + "+0000"
# zone (cljw ships no tz/locale database; matches a TZ=UTC/en JVM exactly).
assert_eq 't_F_T'   "$("$BIN" -e '(format "%tF %tT" 1234567890123 1234567890123)')" '"2009-02-13 23:31:30"'
assert_eq 't_epoch0' "$("$BIN" -e '(format "%tY/%tm/%td %tH:%tM:%tS.%tL" 0 0 0 0 0 0 0)')" '"1970/01/01 00:00:00.000"'
assert_eq 't_names' "$("$BIN" -e '(format "%ta %tA %tb %tB %tp %tz %tZ" 0 0 0 0 0 0 0)')" '"Thu Thursday Jan January am +0000 UTC"'
assert_eq 't_comp'  "$("$BIN" -e '(format "%tD|%tr|%tj|%ts|%tQ" 1234567890123 1234567890123 1234567890123 1234567890123 1234567890123)')" '"02/13/09|11:31:30 PM|044|1234567890|1234567890123"'
assert_eq 't_date'  "$("$BIN" -e '(format "%tF" (java.util.Date. 86400000))')" '"1970-01-02"'
assert_eq 'T_upper' "$("$BIN" -e '(format "%TA" 0)')" '"THURSDAY"'
assert_has 't_badsub' "$("$BIN" -e '(format "%tq" 0)' 2>&1)" 'unsupported directive'

# errors
assert_has 'badtype' "$("$BIN" -e '(format "%d" "x")' 2>&1)"     'expected an integer'
assert_has 'fewargs' "$("$BIN" -e '(format "%d")' 2>&1)"         'not enough arguments'
assert_has 'badconv' "$("$BIN" -e '(format "%q" 1)' 2>&1)"       'unsupported directive'
assert_has 'fmtstr'  "$("$BIN" -e '(format 42)' 2>&1)"           'expected string'
echo "OK — phase14_format smoke (48 cases) green"
