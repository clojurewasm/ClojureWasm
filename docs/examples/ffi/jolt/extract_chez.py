"""Copy the Chez build files a jolt binary embeds as data into a directory.

usage: python3 extract_chez.py JOLT_BINARY OUT_DIR

Each file is a pair of ELF symbols, jolt_<name> (bytes) and jolt_<name>_len
(a little-endian u32), in .data. Linux x86_64 only, which is where the
prebuilt jolt lacks a separate Chez for --library.
"""
import struct
import subprocess
import sys

FILES = {
    "jolt_libkernel_a": "libkernel.a",
    "jolt_scheme_h": "scheme.h",
    "jolt_petite_boot": "petite.boot",
    "jolt_scheme_boot": "scheme.boot",
    "jolt_liblz4_a": "liblz4.a",
    "jolt_libz_a": "libz.a",
}


def main(binary, out):
    sections = subprocess.run(["readelf", "-SW", binary], capture_output=True, text=True, check=True).stdout
    data = None
    for line in sections.splitlines():
        if " .data " in line:
            fields = line.split("]")[1].split()
            data = (int(fields[2], 16), int(fields[3], 16))
    if data is None:
        sys.exit("no .data section in " + binary)
    syms = {}
    for line in subprocess.run(["nm", binary], capture_output=True, text=True, check=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2].startswith("jolt_"):
            syms[parts[2]] = int(parts[0], 16)
    blob = open(binary, "rb").read()

    def at(va):
        return va - data[0] + data[1]

    for sym, name in FILES.items():
        if sym not in syms:
            sys.exit("missing symbol " + sym + " (this jolt does not embed its kernel)")
        n = struct.unpack("<I", blob[at(syms[sym + "_len"]):at(syms[sym + "_len"]) + 4])[0]
        with open(out + "/" + name, "wb") as f:
            f.write(blob[at(syms[sym]):at(syms[sym]) + n])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
