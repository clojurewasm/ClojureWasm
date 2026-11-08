;; SPDX-License-Identifier: EPL-2.0
;; cljw.ffi: call C symbols in a shared library (ADR-0202).
;;
;; A thin layer over the native `cljw.ffi/-*` leaves (runtime/cljw/ffi/). The
;; API is shared with clojurust's `clojure.rust.ffi`, so a portable adapter is
;; one reader conditional:
;;
;;   (:require #?(:cljw [cljw.ffi :as ffi] :rust [clojure.rust.ffi :as ffi]))
;;
;; Types: :void (return only) :int :long :double :pointer :string :bytes
;; (argument only). A :pointer argument also takes a primitive array (its
;; storage, no copy); :bytes copies a byte array. At most 6 integer-class and 8 :double arguments; no
;; varargs, no structs by value, no float. Failures are ex-info with
;; {:ffi/error :open|:symbol|:signature|:arity|:arg-type|:closed ...}.
;; Require-on-demand, and present only on x86_64 / aarch64 Linux and macOS.
(ns cljw.ffi
  (:refer-clojure :exclude [bytes]))

(defn open
  "Open the shared library at `path` (absolute, relative, or a bare soname
   resolved by the dynamic loader). Returns an opaque library handle."
  [path]
  (-open path))

(defn close
  "Close `lib`. Idempotent. Calling a function of a closed library throws
   {:ffi/error :closed}."
  [lib]
  (-close lib))

(defn sym
  "The address of symbol `name` in `lib`, as an integer."
  [lib name]
  (-sym lib name))

(defn function
  "A Clojure fn calling C symbol `name` in `lib`. `arg-types` is a vector of
   type keywords and `ret-type` one type keyword, both resolved once, here: an
   unknown type or too many arguments throws {:ffi/error :signature}. Calls
   check the argument count ({:ffi/error :arity}) and each value against its
   type ({:ffi/error :arg-type})."
  [lib name arg-types ret-type]
  (let [f (-prepare lib name (if (sequential? arg-types) (vec arg-types) arg-types) ret-type)]
    (fn ffi-function
      ([] (-invoke lib f))
      ([a] (-invoke lib f a))
      ([a b] (-invoke lib f a b))
      ([a b c] (-invoke lib f a b c))
      ([a b c & more] (apply -invoke lib f a b c more)))))

(defn call
  "Call C symbol `name` in `lib` once: ((function lib name arg-types ret-type) args...)."
  [lib name arg-types ret-type & args]
  (apply (function lib name arg-types ret-type) args))

(defn string
  "Copy the NUL-terminated UTF-8 C string at address `ptr` into a string.
   0 or nil gives nil."
  [ptr]
  (-string ptr))

(defn bytes
  "Copy `n` bytes at address `ptr` into a byte array. 0 or nil gives nil."
  [ptr n]
  (-bytes ptr n))
