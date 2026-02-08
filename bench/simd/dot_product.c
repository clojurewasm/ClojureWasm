// Dot product benchmark — scalar and SIMD variants
// Compile: zig cc -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry dot_product.c -o dot_product.wasm
// Native:  cc -O2 dot_product.c -o dot_product_native

#define N 1000000
#define ITERS 100

static float a[N], b[N];

__attribute__((export_name("init")))
void init(void) {
    for (int i = 0; i < N; i++) {
        a[i] = (float)i * 0.001f;
        b[i] = (float)(N - i) * 0.001f;
    }
}

__attribute__((export_name("dot_product")))
float dot_product(void) {
    float total = 0.0f;
    for (int iter = 0; iter < ITERS; iter++) {
        float sum = 0.0f;
        for (int i = 0; i < N; i++) {
            sum += a[i] * b[i];
        }
        total += sum;
    }
    return total;
}

#ifndef __wasm__
#include <stdio.h>
#include <time.h>
int main(void) {
    init();
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    float result = dot_product();
    clock_gettime(CLOCK_MONOTONIC, &end);
    double ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                (end.tv_nsec - start.tv_nsec) / 1000000.0;
    printf("dot_product: %.2f ms (checksum=%.2f)\n", ms, result);
    return 0;
}
#endif
