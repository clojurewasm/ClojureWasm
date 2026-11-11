#!/bin/sh
# Build the jolt library and the C driver into build/.
#
#   sh docs/examples/ffi/jolt/build.sh
#
# Needs jolt on PATH, a C compiler, and (Linux) libtinfo for the Chez kernel.
# If JOLT_CHEZ_CSV is unset and no `chez` is on PATH, the Chez build files are
# pulled out of the jolt binary and a `chez` front end is linked from them.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"
mkdir -p "$out"
cc=${CC:-cc}

if [ -z "${JOLT_CHEZ_CSV:-}" ] || ! command -v chez >/dev/null 2>&1; then
  csv="$out/chez/ta6le"
  if [ ! -x "$out/chez/bin/chez" ]; then
    mkdir -p "$csv" "$out/chez/bin"
    python3 "$here/extract_chez.py" "$(command -v jolt)" "$csv"
    "$cc" -O2 -I "$csv" -DBOOTDIR="\"$csv\"" "$here/chez.c" \
      "$csv/libkernel.a" "$csv/liblz4.a" "$csv/libz.a" \
      -lm -ldl -lpthread -ltinfo -o "$out/chez/bin/chez"
  fi
  export JOLT_CHEZ_CSV="$csv"
  PATH="$out/chez/bin:$PATH"
  export PATH
fi

cd "$here"
jolt build --library -m demo.core -o "$out/libdemo"
"$cc" -O2 "$here/driver.c" -ldl -o "$out/driver"
echo "built $out/libdemo.so $out/driver"
