# Java Interop Reference

CW provides a compatibility layer for commonly-used Java interop patterns.
This is not a full JVM — only the classes and methods listed here are supported.

## Supported Classes

### java.net.URI

```clojure
(URI. "https://example.com/path?q=1#frag")

(.getScheme uri)     ; => "https"
(.getHost uri)       ; => "example.com"
(.getPort uri)       ; => -1 (or port number)
(.getPath uri)       ; => "/path"
(.getQuery uri)      ; => "q=1"
(.getFragment uri)   ; => "frag"
(.getAuthority uri)  ; => "example.com"
(.toString uri)      ; => full URI string
(.toASCIIString uri) ; => full URI string

(URI/create "https://example.com")  ; static constructor
```

### java.io.File

```clojure
(File. "/path/to/file")
(File. "/parent" "child")

(.getPath f)         ; => "/path/to/file"
(.getName f)         ; => "file"
(.getParent f)       ; => "/path/to" (or nil)
(.getAbsolutePath f) ; => absolute path
(.exists f)          ; => true/false
(.isDirectory f)     ; => true/false
(.isFile f)          ; => true/false
(.canRead f)         ; => true/false
(.canWrite f)        ; => true/false
(.length f)          ; => size in bytes
(.delete f)          ; => true/false
(.mkdir f)           ; => true/false
(.mkdirs f)          ; => true/false
(.list f)            ; => ["file1" "file2" ...]
(.lastModified f)    ; => millis since epoch

File/separator       ; => "/"
File/pathSeparator   ; => ":"
```

### java.util.UUID

```clojure
(UUID/randomUUID)                    ; => random UUID v4
(UUID/fromString "550e8400-...")      ; => parsed UUID
(UUID. msb lsb)                      ; => from bits
(UUID. "550e8400-...")               ; => from string

(.toString uuid)
(.getMostSignificantBits uuid)
(.getLeastSignificantBits uuid)
(.version uuid)
(.variant uuid)
```

### java.io.PushbackReader

```clojure
(PushbackReader. (StringReader. "hello"))

(.read pbr)      ; => char code (int), -1 on EOF
(.unread pbr ch) ; => pushes back a character
(.readLine pbr)  ; => string or nil
(.ready pbr)     ; => true/false
(.close pbr)     ; => nil
```

### java.lang.StringBuilder

```clojure
(StringBuilder.)
(StringBuilder. "initial")

(.append sb "text")   ; => sb (chainable)
(.append sb \c)       ; => sb
(.append sb 65)       ; => sb (appends char for codepoint)
(.toString sb)        ; => accumulated string
(.length sb)          ; => current length
```

### java.io.StringWriter

```clojure
(StringWriter.)

(.write sw "text")    ; => nil
(.write sw 65)        ; => nil (writes char)
(.append sw "text")   ; => sw (chainable)
(.toString sw)        ; => accumulated string
(.close sw)           ; => nil
```

### java.io.BufferedWriter

Created by `clojure.java.io/writer`. Buffers content in memory and
writes to file on flush/close.

```clojure
(require '[clojure.java.io :as io])
(with-open [w (io/writer "/tmp/out.txt")]
  (.write w "hello\n")
  (.newLine w))
```

Methods: `.write`, `.newLine`, `.flush`, `.close`, `.toString`.

## String Methods

Native strings support Java-compatible method calls:

```clojure
(.length "hello")           ; => 5
(.substring "hello" 1 3)    ; => "el"
(.charAt "hello" 0)         ; => \h
(.indexOf "hello" "ll")     ; => 2
(.contains "hello" "ell")   ; => true
(.startsWith "hello" "he")  ; => true
(.endsWith "hello" "lo")    ; => true
(.toUpperCase "hello")      ; => "HELLO"
(.toLowerCase "HELLO")      ; => "hello"
(.trim "  hi  ")            ; => "hi"
(.replace "hello" "l" "r")  ; => "herro"
(.isEmpty "")               ; => true
(.equals "a" "a")           ; => true
(.compareTo "a" "b")        ; => -1
(.concat "he" "llo")        ; => "hello"
```

## Static Method Rewrites

Java static method calls are rewritten to CW builtins:

### Math

```clojure
Math/PI                     ; => 3.141592653589793
Math/E                      ; => 2.718281828459045
(Math/abs -5)               ; => 5
(Math/pow 2 10)             ; => 1024.0
(Math/sqrt 16)              ; => 4.0
(Math/round 3.7)            ; => 4
(Math/ceil 3.2)             ; => 4.0
(Math/floor 3.8)            ; => 3.0
(Math/max 1 2)              ; => 2
(Math/min 1 2)              ; => 1
```

### System

```clojure
(System/getenv "HOME")          ; => "/Users/..."
(System/exit 0)                 ; => exits process
(System/nanoTime)               ; => nanoseconds
(System/currentTimeMillis)      ; => millis since epoch
(System/getProperty "os.name")  ; => "Mac OS X" etc.
```

### Parsing

```clojure
(Integer/parseInt "42")     ; => 42
(Long/parseLong "42")       ; => 42
(Double/parseDouble "3.14") ; => 3.14
(Boolean/parseBoolean "true") ; => true
```

### String Static Methods

```clojure
(String/valueOf 42)         ; => "42"
(String/format "%d + %d = %d" 1 2 3)  ; => "1 + 2 = 3"
(String/join ", " ["a" "b" "c"])       ; => "a, b, c"
```

### Character

```clojure
(Character/isDigit \5)      ; => true
(Character/isLetter \a)     ; => true
(Character/isWhitespace \ ) ; => true
(Character/isUpperCase \A)  ; => true
(Character/isLowerCase \a)  ; => true
```

### Numeric Constants

```clojure
Integer/MAX_VALUE    ; => 2147483647
Long/MAX_VALUE       ; => 9223372036854775807
Double/NaN           ; => NaN
Double/POSITIVE_INFINITY
Double/NEGATIVE_INFINITY
```

### Regex

```clojure
(Pattern/compile "\\d+")   ; => regex pattern
(Pattern/quote "a.b")      ; => "\\Qa.b\\E"
```

## Exceptions

```clojure
(throw (Exception. "message"))
(throw (RuntimeException. "message"))
(throw (ex-info "message" {:key "val"}))

(try
  (/ 1 0)
  (catch Exception e
    (println (.getMessage e))))
```

## Not Supported

The following Java interop patterns are not available:

- `proxy`, `gen-class`, `gen-interface`, `deftype`, `definterface`
- `import` (classes are available by their simple name)
- Java class hierarchy, inheritance, interfaces
- Java reflection (`clojure.reflect`)
- Swing/AWT (`clojure.inspector`)
- JDBC, JMX, classloaders
- Custom Java class instantiation
