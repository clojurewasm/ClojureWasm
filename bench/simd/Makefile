# SIMD benchmark build targets
# Requires: zig (for wasm32-wasi cross-compile), cc (native)

ZIG_CC = zig cc
WASM_FLAGS = -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry
WASM_SIMD_FLAGS = $(WASM_FLAGS) -msimd128
NATIVE_FLAGS = -O2

SOURCES = vector_add dot_product matrix_mul mandelbrot
WASM_TARGETS = $(addsuffix .wasm, $(SOURCES))
WASM_SIMD_TARGETS = $(addsuffix _simd.wasm, $(SOURCES))
NATIVE_TARGETS = $(addsuffix _native, $(SOURCES))

.PHONY: all clean wasm wasm-simd native

all: wasm wasm-simd native

wasm: $(WASM_TARGETS)

wasm-simd: $(WASM_SIMD_TARGETS)

native: $(NATIVE_TARGETS)

%.wasm: %.c
	$(ZIG_CC) $(WASM_FLAGS) $< -o $@

%_simd.wasm: %.c
	$(ZIG_CC) $(WASM_SIMD_FLAGS) $< -o $@

%_native: %.c
	cc $(NATIVE_FLAGS) $< -o $@

clean:
	rm -f $(WASM_TARGETS) $(WASM_SIMD_TARGETS) $(NATIVE_TARGETS)
