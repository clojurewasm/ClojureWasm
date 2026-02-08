// Vector addition benchmark — scalar and SIMD variants
// Compile: zig cc -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry vector_add.c -o vector_add.wasm
// Native:  cc -O2 vector_add.c -o vector_add_native

#define N 1000000
#define ITERS 100

static float a[N], b[N], c[N];

__attribute__((export_name("init")))
void init(void) {
    for (int i = 0; i < N; i++) {
        a[i] = (float)i * 0.5f;
        b[i] = (float)i * 0.3f;
    }
}

__attribute__((export_name("vector_add")))
float vector_add(void) {
    for (int iter = 0; iter < ITERS; iter++) {
        for (int i = 0; i < N; i++) {
            c[i] = a[i] + b[i];
        }
    }
    // Return checksum to prevent dead-code elimination
    float sum = 0.0f;
    for (int i = 0; i < N; i += 1000) {
        sum += c[i];
    }
    return sum;
}

#ifndef __wasm__
#include <stdio.h>
#include <time.h>
int main(void) {
    init();
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    float result = vector_add();
    clock_gettime(CLOCK_MONOTONIC, &end);
    double ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                (end.tv_nsec - start.tv_nsec) / 1000000.0;
    printf("vector_add: %.2f ms (checksum=%.2f)\n", ms, result);
    return 0;
}
#endif
