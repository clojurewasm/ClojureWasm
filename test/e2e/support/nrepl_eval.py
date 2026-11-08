#!/usr/bin/env python3
"""Evaluate one string over nREPL bencode and print what the session printed.

Shared by the e2e steps that need a real nREPL round trip (the classpath,
top-level-`do`, and entry-point-parity suites each grew their own copy of this
before it was extracted).

Usage: nrepl_eval.py <port> <code>

Prints the session's captured stdout (`out` frames) followed by its `value`
frames, one per line — so a program written as `(println …)` compares equal to
the same program run through the CLI, which is what the parity oracle needs.
Errors are printed as `ERR <text>` rather than raising, so a caller diffing
entry points sees the divergence instead of a traceback.
"""
import socket
import sys
import time


def encode(v):
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, (bytes, str)):
        b = v.encode() if isinstance(v, str) else v
        return b"%d:" % len(b) + b
    if isinstance(v, list):
        return b"l" + b"".join(encode(x) for x in v) + b"e"
    if isinstance(v, dict):
        out = b"d"
        for k in sorted(v):
            out += encode(k) + encode(v[k])
        return out + b"e"
    raise ValueError(type(v))


def decode(buf, i=0):
    c = buf[i:i + 1]
    if c == b"i":
        j = buf.index(b"e", i)
        return int(buf[i + 1:j]), j + 1
    if c.isdigit():
        j = buf.index(b":", i)
        n = int(buf[i:j])
        return buf[j + 1:j + 1 + n], j + 1 + n
    if c == b"l":
        i += 1
        out = []
        while buf[i:i + 1] != b"e":
            v, i = decode(buf, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        i += 1
        out = {}
        while buf[i:i + 1] != b"e":
            k, i = decode(buf, i)
            v, i = decode(buf, i)
            out[k.decode()] = v
        return out, i + 1
    raise ValueError(buf[i:i + 4])


def main():
    port, code = int(sys.argv[1]), sys.argv[2]
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.settimeout(10)
    s.sendall(encode({"op": "eval", "code": code, "id": "1"}))
    buf, t0 = b"", time.time()
    while time.time() - t0 < 10:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        if b"done" in buf:
            break

    printed, values, errors = [], [], []
    i = 0
    while i < len(buf):
        try:
            m, i = decode(buf, i)
        except Exception:
            break
        if "out" in m:
            printed.append(m["out"].decode())
        if "value" in m:
            values.append(m["value"].decode())
        if "err" in m:
            errors.append(m["err"].decode().replace("\n", " "))

    for line in "".join(printed).splitlines():
        print(line)
    # A program that only printed has `nil` as its value; suppress that so it
    # compares equal to the CLI, which prints nothing for a nil-returning form.
    for v in values:
        if v != "nil":
            print(v)
    for e in errors:
        print("ERR " + e)


if __name__ == "__main__":
    main()
