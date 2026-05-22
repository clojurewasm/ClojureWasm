---
paths:
  - src/runtime/host/**
---

# Host extension directory layout

## Rule

cw v1 host stdlib equivalents live under `src/runtime/host/` mirroring
the Java package structure:

```
src/runtime/host/
├── lang/        Object, String, Long, Math, System, Thread
├── io/          File, PrintWriter, ByteArrayInputStream, etc.
├── util/        UUID, Date, Random, Locale, regex/Pattern
├── time/        Instant, LocalDate, LocalDateTime, Duration
├── net/         URL, URI, Socket (Phase 14+)
├── nio/         file/Path, file/Files, charset/Charset
├── math/        BigInteger, BigDecimal
├── security/    MessageDigest, SecureRandom (Phase 14+)
├── sql/         Connection, Statement, ResultSet (Phase 14+)
├── text/        SimpleDateFormat, DecimalFormat (Tier B)
├── reflect/     Method, Field (thin, via TypeDescriptor)
└── concurrent/  atomic.*, locks.* (Phase 15)
```

Each `.zig` file under `src/runtime/host/` registers itself via the
`___HOST_EXTENSION` marker (see ADR-0011).

## Why

- A consistent layout makes "what cw provides for java.X" predictable.
- New host stdlib additions plug in without `class_registry.zig`-style
  central registration.
- The structure documents cw v1's Java compatibility surface as code,
  not narrative.

## How to apply

- New Java equivalent type goes in the package-mirrored subdirectory.
- Registration is via the `___HOST_EXTENSION` marker (per `_host_api.zig`).
- The cw namespace mirrors the directory
  (`cljw.host.java.util.UUID` and so on).
