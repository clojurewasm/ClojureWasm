#!/usr/bin/env python3
"""Generate the Unicode character-NAME table (D-561: Character/getName +
Character/codePointOf) from the UCD definition (16.0.0, pinned — same
source + cache convention as gen_unicode_case.py; F-013: derived from the
definition, never hand-rolled).

Format (word-indexed, flate-lazy at the consumer):
  - `words_blob`  — every distinct name word, concatenated, '\\n'-separated,
    in frequency order (small indices = frequent words).
  - `names_blob`  — per named codepoint: varint word-index sequence.
    A name is its words joined by ' ' — EXCEPT '-' which UCD embeds
    without spaces; a word carrying a trailing '-' marker (index bit)
    joins to the NEXT word with no space. Encoded per word as
    `(word_idx << 1) | joins_next_without_space`.
  - `cp_index`    — sorted (codepoint, names_blob offset) pairs for
    binary-searched getName; codePointOf scans the same structures.
  - ALGORITHMIC ranges (CJK UNIFIED IDEOGRAPH-*, TANGUT/KHITAN/NUSHU/
    HANGUL SYLLABLE composition, and <control> labels) are NOT in the
    table — the Zig consumer derives them (JVM does the same).

Both blobs are emitted RAW here; `build.zig`'s existing flate step (the
ADR-0173 embedded-asset pattern) compresses them like the .clj sources.
Output .zig is committed; run this script only to regenerate on a UCD bump.
"""

import sys
import urllib.request
from pathlib import Path

UCD_VERSION = "16.0.0"
BASE = f"https://www.unicode.org/Public/{UCD_VERSION}/ucd"
OUT = Path(__file__).resolve().parent.parent / "src/runtime/unicode_names.zig"


def fetch(name: str) -> str:
    cache = Path(f"/tmp/ucd_{UCD_VERSION}_{name.replace('/', '_')}")
    if cache.exists():
        return cache.read_text()
    print(f"downloading {name} …", file=sys.stderr)
    text = urllib.request.urlopen(f"{BASE}/{name}").read().decode()
    cache.write_text(text)
    return text


def tokenize(name: str):
    """Split a UCD name into (word, joins_next_without_space) tokens.

    UCD names are words joined by ' ' or '-'. We split on both and record,
    per token, whether the ORIGINAL separator after it was '-' (join with
    no space, emitting the '-' back) or ' '. The '-' itself is re-attached
    to the preceding token at decode ('A-B' → [('A-', join), ('B', end)]).
    """
    toks = []
    cur = ""
    for ch in name:
        if ch == " ":
            toks.append((cur, False))
            cur = ""
        elif ch == "-":
            toks.append((cur + "-", True))
            cur = ""
        else:
            cur += ch
    toks.append((cur, False))
    return toks


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def main() -> None:
    names = []
    for line in fetch("UnicodeData.txt").splitlines():
        f = line.split(";")
        if len(f) < 2 or f[1].startswith("<"):
            continue  # ranges/controls: algorithmic or label-less (JVM parity)
        cp = int(f[0], 16)
        # Every '<'-labelled row is a range marker / control label. The JVM
        # names RANGE chars as "<BLOCK NAME> <HEX>" (oracle:
        # (Character/getName 0x17000) => "TANGUT 17000") and controls via
        # pinned aliases — both consumer-derived. Every NAMED per-cp row
        # (incl. hex-suffixed families like CJK COMPATIBILITY
        # IDEOGRAPH-F900) is stored.
        names.append((cp, f[1]))
    names.sort()

    # CPHEX compression: a trailing token equal to the codepoint's own
    # uppercase hex ("CJK COMPATIBILITY IDEOGRAPH-F900" and the other
    # hex-suffixed families) is stored as RESERVED word index 0 — the
    # decoder re-derives it from the codepoint, keeping ~1k one-off hex
    # words out of the dictionary.
    def tokens_for(cp: int, n: str):
        toks = tokenize(n)
        out = []
        hexes = (f"{cp:04X}", f"{cp:X}")
        for i, (w, j) in enumerate(toks):
            if i == len(toks) - 1 and w in hexes:
                out.append((None, j))  # None = CPHEX sentinel
            else:
                out.append((w, j))
        return out

    # Frequency-ordered word dictionary (small varints for frequent words;
    # index 0 is the CPHEX sentinel, emitted as an empty dictionary row).
    freq: dict[str, int] = {}
    for cp, n in names:
        for w, _j in tokens_for(cp, n):
            if w is not None:
                freq[w] = freq.get(w, 0) + 1
    words = sorted(freq, key=lambda w: (-freq[w], w))
    word_idx = {w: i + 1 for i, w in enumerate(words)}

    words_blob = "\n".join([""] + words).encode()

    names_blob = bytearray()
    cp_entries = []  # (cp, offset, token_count)
    for cp, n in names:
        toks = tokens_for(cp, n)
        cp_entries.append((cp, len(names_blob), len(toks)))
        for w, join in toks:
            idx = 0 if w is None else word_idx[w]
            names_blob += varint((idx << 1) | (1 if join else 0))

    lines = []
    lines.append("// SPDX-License-Identifier: EPL-2.0")
    lines.append("//! GENERATED by scripts/gen_unicode_names.py — do NOT edit.")
    lines.append(f"//! Unicode character names, UCD {UCD_VERSION} (D-561:")
    lines.append("//! Character/getName + Character/codePointOf). Word-indexed:")
    lines.append("//! `words` is the frequency-ordered distinct-word blob;")
    lines.append("//! `names` is per-codepoint varint word-index sequences")
    lines.append("//! (`(idx << 1) | joins-next-without-space`); `cp_index` maps")
    lines.append("//! sorted codepoints to (offset, token count). Algorithmic")
    lines.append("//! families (CJK/TANGUT/… IDEOGRAPH-N, HANGUL SYLLABLE) are")
    lines.append("//! DERIVED by the consumer, not stored (JVM parity).")
    lines.append("")
    lines.append(f"pub const named_count: u32 = {len(cp_entries)};")
    lines.append(f"pub const word_count: u32 = {len(words) + 1};  // incl. the CPHEX sentinel at index 0")

    import zlib

    def blob_literal(name: str, raw: bytes) -> None:
        # Pre-compress with RAW deflate (matches serialize.zig's
        # `flateDecompress(..., .raw, ...)`) and emit the COMPRESSED bytes as
        # a Zig string literal + the uncompressed length. The consumer
        # (char_name.zig) decompresses once on first use.
        co = zlib.compressobj(9, zlib.DEFLATED, -15)
        data = co.compress(raw) + co.flush()
        chunks = []
        for i in range(0, len(data), 4096):
            part = data[i : i + 4096]
            esc = "".join(
                chr(b) if 32 <= b < 127 and chr(b) not in '"\\' else f"\\x{b:02x}"
                for b in part
            )
            chunks.append(f'    "{esc}"')
        lines.append(f"pub const {name}_len: u32 = {len(raw)};")
        lines.append(f"pub const {name}_deflate: []const u8 =")
        lines.append(" ++\n".join(chunks) + ";")

    # Index blob: DELTA-VARINT stream (cp and offset are both strictly
    # increasing) — per record: varint(cp_delta), then
    # varint((offset_delta << 5) | tokens) (tokens < 32 — asserted). The
    # consumer decodes once into fixed in-memory records for binary search;
    # the wire form is ~4× smaller than fixed 8-byte records and deflates
    # further (the fixed form dominated the binary delta at +394 KB).
    assert all(t < 32 for _, _, t in cp_entries)
    index_blob = bytearray()
    prev_cp = 0
    prev_off = 0
    for cp, off, toks in cp_entries:
        index_blob += varint(cp - prev_cp)
        index_blob += varint(((off - prev_off) << 5) | toks)
        prev_cp, prev_off = cp, off

    blob_literal("words", words_blob)
    blob_literal("names", bytes(names_blob))
    blob_literal("cp_index", bytes(index_blob))
    lines.append("")

    # Blocks.txt — the JVM's fallback name for an assigned-but-unnamed char
    # is "<BLOCK NAME UPPERCASED> <HEX>" (oracle: "TANGUT 17000",
    # "HANGUL SYLLABLES AC00", "PRIVATE USE AREA E000"). ~340 rows.
    lines.append("pub const Block = struct { lo: u21, hi: u21, name: []const u8 };")
    lines.append("pub const blocks = [_]Block{")
    for line in fetch("Blocks.txt").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        rng, _, bname = line.partition("; ")
        lo, _, hi = rng.partition("..")
        lines.append(f'    .{{ .lo = 0x{lo}, .hi = 0x{hi}, .name = "{bname.upper()}" }},')
    lines.append("};")
    lines.append("")
    # Control-char names: pinned from the LIVE JVM oracle
    # (scripts/data/jvm_control_names.txt — see its provenance header) rather
    # than re-deriving NameAliases.txt's preference rule.
    lines.append("pub const CtlName = struct { cp: u21, name: []const u8 };")
    lines.append("pub const control_names = [_]CtlName{")
    pin = Path(__file__).resolve().parent / "data/jvm_control_names.txt"
    for line in pin.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        cp_s, _, cn = line.partition(" ")
        lines.append(f'    .{{ .cp = 0x{int(cp_s):02X}, .name = "{cn}" }},')
    lines.append("};")
    lines.append("")

    OUT.write_text("\n".join(lines))
    total = len(words_blob) + len(names_blob) + len(cp_entries) * 6
    print(
        f"wrote {OUT} — {len(cp_entries)} names, {len(words)} words; "
        f"words {len(words_blob)/1024:.0f} KB + names {len(names_blob)/1024:.0f} KB "
        f"+ index {(len(cp_entries)*6)/1024:.0f} KB ≈ {total/1024:.0f} KB raw"
    )


if __name__ == "__main__":
    main()
