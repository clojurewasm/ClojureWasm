// 4x4 matrix multiplication benchmark — scalar variant
// Compile: zig cc -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry matrix_mul.c -o matrix_mul.wasm
// Native:  cc -O2 matrix_mul.c -o matrix_mul_native

#define ITERS 10000000

static float a[16], b[16], c[16];

__attribute__((export_name("init")))
void init(void) {
    for (int i = 0; i < 16; i++) {
        a[i] = (float)(i + 1);
        b[i] = (float)(16 - i);
    }
}

static void mat4_mul(float *dst, const float *m1, const float *m2) {
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            float sum = 0.0f;
            for (int k = 0; k < 4; k++) {
                sum += m1[row * 4 + k] * m2[k * 4 + col];
            }
            dst[row * 4 + col] = sum;
        }
    }
}

__attribute__((export_name("matrix_mul")))
float matrix_mul(void) {
    for (int i = 0; i < ITERS; i++) {
        mat4_mul(c, a, b);
        // Feed back to prevent optimization
        a[0] = c[0] * 0.0001f + (float)(i % 16 + 1);
    }
    return c[0] + c[5] + c[10] + c[15]; // trace
}

#ifndef __wasm__
#include <stdio.h>
#include <time.h>
int main(void) {
    init();
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    float result = matrix_mul();
    clock_gettime(CLOCK_MONOTONIC, &end);
    double ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                (end.tv_nsec - start.tv_nsec) / 1000000.0;
    printf("matrix_mul: %.2f ms (checksum=%.2f)\n", ms, result);
    return 0;
}
#endif
