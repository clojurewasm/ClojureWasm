# Babashka Java Class Compatibility

CW vs Babashka Java interop class support.
Source: `babashka/src/babashka/impl/classes.clj` (250+ classes).

Legend:
- **Done**: Fully or partially implemented in CW
- **Feasible**: Can implement with Zig std or pure logic
- **Hard**: Requires OS/runtime features difficult in Zig
- **N/A**: JVM-specific, not applicable to CW
- **Priority**: H=high (libraries need it), M=medium, L=low

## java.lang (auto-imported, no `:import` needed)

| Class                    | BB     | CW          | Priority | Notes                                                    |
|--------------------------|--------|-------------|----------|----------------------------------------------------------|
| Math                     | All    | **Done**    | -        | Static fields + methods via rewrites.zig + math.zig      |
| System                   | All    | **Done**    | -        | exit, getenv, nanoTime, currentTimeMillis, getProperty   |
| String                   | All    | **Done**    | -        | Instance methods via dispatch.zig                        |
| Integer                  | All    | **Done**    | -        | Fields + static methods (parseInt, toBinaryString, etc.) |
| Long                     | All    | **Done**    | -        | Fields + static methods                                  |
| Double                   | All    | **Done**    | -        | Fields + static methods (parseDouble, isNaN, isInfinite) |
| Float                    | All    | **Done**    | -        | Fields + static methods                                  |
| Short                    | All    | **Done**    | -        | Fields                                                   |
| Byte                     | All    | **Done**    | -        | Fields                                                   |
| Boolean                  | All    | **Done**    | -        | Fields + static methods                                  |
| Character                | All    | **Done**    | -        | Fields + static methods (isDigit, isLetter, etc.)        |
| Thread                   | Custom | **Partial** | M        | sleep only. Missing: currentThread, getName, etc.        |
| StringBuilder            | All    | Todo        | M        | Feasible: mutable string buffer                          |
| Runtime                  | All    | Todo        | L        | getRuntime, availableProcessors, freeMemory              |
| Process                  | All    | Todo        | M        | For shell integration (sh already exists)                |
| ProcessBuilder           | All    | Todo        | M        | For shell integration                                    |
| Object                   | All    | N/A         | -        | Implicit in CW's value system                            |
| Class                    | Custom | N/A         | -        | JVM reflection                                           |
| Number                   | All    | N/A         | -        | Abstract base, CW uses Value tags                        |
| Throwable                | All    | **Done**    | -        | Via ex-info/ex-message/ex-data                           |
| Exception                | All    | **Done**    | -        | Constructor support                                      |
| RuntimeException         | All    | **Done**    | -        | Maps to CW error system                                  |
| IllegalArgumentException | All    | **Done**    | -        | Via error system                                         |
| StackTraceElement        | All    | N/A         | -        | No JVM stack traces                                      |
| ClassLoader              | Custom | N/A         | -        | JVM-specific                                             |

## java.io

| Class                 | BB  | CW       | Priority | Notes                                        |
|-----------------------|-----|----------|----------|----------------------------------------------|
| File                  | All | **Done** | -        | classes/file.zig, full constructor + methods |
| BufferedReader        | All | Todo     | H        | Libraries use for line-by-line reading       |
| BufferedWriter        | All | Todo     | H        | Libraries use for writing                    |
| FileReader            | All | Todo     | M        | Feasible via std.fs                          |
| FileWriter            | All | Todo     | M        | Feasible via std.fs                          |
| StringReader          | All | Todo     | H        | clojure.edn, many parsers need this          |
| StringWriter          | All | Todo     | H        | Many libraries use for str capture           |
| InputStream           | All | Todo     | H        | Abstract base, needed for many libs          |
| OutputStream          | All | Todo     | H        | Abstract base, needed for many libs          |
| InputStreamReader     | All | Todo     | M        | Wraps InputStream                            |
| OutputStreamWriter    | All | Todo     | M        | Wraps OutputStream                           |
| PrintWriter           | All | Todo     | M        | For formatted output                         |
| PushbackReader        | All | Todo     | H        | clojure.core/read needs this                 |
| ByteArrayInputStream  | All | Todo     | M        | In-memory stream                             |
| ByteArrayOutputStream | All | Todo     | M        | In-memory stream                             |
| Reader                | All | Todo     | H        | Abstract base for readers                    |
| Writer                | All | Todo     | H        | Abstract base for writers                    |
| IOException           | All | Todo     | M        | Exception type                               |
| FileNotFoundException | All | Todo     | M        | Exception type                               |
| Closeable             | All | N/A      | -        | Interface, CW uses defer                     |

## java.net

| Class             | BB     | CW       | Priority | Notes                       |
|-------------------|--------|----------|----------|-----------------------------|
| URI               | All    | **Done** | -        | classes/uri.zig             |
| URL               | Custom | Todo     | H        | Many libraries use URL      |
| URLEncoder        | All    | Todo     | H        | Web libraries need this     |
| URLDecoder        | All    | Todo     | H        | Web libraries need this     |
| Socket            | All    | Todo     | M        | Feasible via std.net        |
| ServerSocket      | All    | Todo     | M        | Feasible via std.net        |
| InetAddress       | All    | Todo     | M        | Feasible via std.net        |
| HttpURLConnection | All    | Hard     | L        | Full HTTP client is complex |

## java.util

| Class          | BB      | CW       | Priority | Notes                             |
|----------------|---------|----------|----------|-----------------------------------|
| UUID           | All     | **Done** | -        | classes/uuid.zig                  |
| Base64         | All     | Todo     | H        | Many libraries need encoding      |
| Base64$Decoder | All     | Todo     | H        | std.base64 available              |
| Base64$Encoder | All     | Todo     | H        | std.base64 available              |
| Date           | All     | Todo     | M        | Legacy but widely used            |
| Properties     | All     | Todo     | M        | Config file reading               |
| Random         | All     | Todo     | L        | CW has std.crypto.random          |
| regex.Pattern  | All     | **Done** | -        | Via re-pattern, regex/ module     |
| regex.Matcher  | All     | **Done** | -        | Via re-find, re-matches, etc.     |
| Arrays         | Custom  | Todo     | L        | copyOf, fill                      |
| Collections    | All     | N/A      | -        | CW uses persistent collections    |
| HashMap        | All     | N/A      | -        | CW uses PersistentHashMap         |
| ArrayList      | All     | N/A      | -        | CW uses PersistentVector          |
| LinkedList     | All     | N/A      | -        | CW uses PersistentList            |
| HashSet        | All     | N/A      | -        | CW uses PersistentHashSet         |
| concurrent.*   | Various | Todo     | L        | Atoms/agents cover most use cases |

## java.math

| Class        | BB  | CW       | Priority | Notes                     |
|--------------|-----|----------|----------|---------------------------|
| BigDecimal   | All | **Done** | -        | Native BigDecimal support |
| BigInteger   | All | **Done** | -        | Native BigInt support     |
| MathContext  | All | Todo     | L        | Precision control         |
| RoundingMode | All | Todo     | L        | For BigDecimal operations |

## java.time

| Class             | BB  | CW   | Priority | Notes                         |
|-------------------|-----|------|----------|-------------------------------|
| Instant           | All | Todo | H        | Modern date/time, widely used |
| LocalDate         | All | Todo | H        | Date without time             |
| LocalDateTime     | All | Todo | H        | Date + time                   |
| LocalTime         | All | Todo | M        | Time without date             |
| ZonedDateTime     | All | Todo | H        | Date + time + zone            |
| ZoneId            | All | Todo | H        | Time zones                    |
| Duration          | All | Todo | H        | Time durations                |
| Period            | All | Todo | M        | Date-based periods            |
| DateTimeFormatter | All | Todo | H        | Formatting/parsing            |
| Clock             | All | Todo | M        | Time source                   |
| DayOfWeek         | All | Todo | L        | Enum                          |
| Month             | All | Todo | L        | Enum                          |

## java.nio.file

| Class              | BB  | CW   | Priority | Notes                             |
|--------------------|-----|------|----------|-----------------------------------|
| Path               | All | Todo | H        | Modern file paths (many libs use) |
| Paths              | All | Todo | H        | Path factory                      |
| Files              | All | Todo | H        | Modern file operations            |
| FileSystem         | All | Todo | M        | File system access                |
| StandardOpenOption | All | Todo | M        | File open options                 |

## java.security

| Class         | BB  | CW   | Priority | Notes                         |
|---------------|-----|------|----------|-------------------------------|
| MessageDigest | All | Todo | M        | SHA, MD5 hashing (std.crypto) |
| SecureRandom  | All | Todo | L        | std.crypto.random available   |

## Summary

### Current CW Coverage

| Category         | Done   | Total BB | Coverage |
|------------------|--------|----------|----------|
| java.lang (core) | 12     | ~30      | 40%      |
| java.io          | 1      | ~40      | 3%       |
| java.net         | 1      | ~25      | 4%       |
| java.util        | 3      | ~50      | 6%       |
| java.math        | 2      | 4        | 50%      |
| java.time        | 0      | ~30      | 0%       |
| java.nio         | 0      | ~35      | 0%       |
| **Total**        | **19** | **~250** | **~8%**  |

### Recommended Priority Order

1. **I/O streams** (Reader, Writer, InputStream, OutputStream, StringReader, StringWriter)
   - Unblocks: clojure.edn, many parsing libraries
2. **Base64** (Encoder, Decoder)
   - Unblocks: web libraries, data encoding
3. **java.time core** (Instant, LocalDate, ZonedDateTime, Duration, DateTimeFormatter)
   - Unblocks: date/time libraries (tick, clj-time replacement)
4. **URL + URLEncoder/URLDecoder**
   - Unblocks: web libraries (ring, http-kit)
5. **nio.file** (Path, Paths, Files)
   - Unblocks: modern file operations
6. **StringBuilder**
   - Unblocks: performance-sensitive string building
