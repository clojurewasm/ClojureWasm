# SIMD benchmark build targets
# Requires: zig (for wasm32-wasi cross-compile), cc (native)

ZIG_CC = zig cc
WASM_FLAGS = -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry
NATIVE_FLAGS = -O2

SOURCES = vector_add dot_product matrix_mul mandelbrot
WASM_TARGETS = $(addsuffix .wasm, $(SOURCES))
NATIVE_TARGETS = $(addsuffix _native, $(SOURCES))

.PHONY: all clean wasm native

all: wasm native

wasm: $(WASM_TARGETS)

native: $(NATIVE_TARGETS)

%.wasm: %.c
	$(ZIG_CC) $(WASM_FLAGS) $< -o $@

%_native: %.c
	cc $(NATIVE_FLAGS) $< -o $@

clean:
	rm -f $(WASM_TARGETS) $(NATIVE_TARGETS)
