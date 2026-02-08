// Mandelbrot set computation benchmark — scalar variant
// Compile: zig cc -target wasm32-wasi -O2 -nostdlib -Wl,--no-entry mandelbrot.c -o mandelbrot.wasm
// Native:  cc -O2 mandelbrot.c -o mandelbrot_native

#define WIDTH 512
#define HEIGHT 512
#define MAX_ITER 100

static int pixels[WIDTH * HEIGHT];

__attribute__((export_name("mandelbrot")))
int mandelbrot(void) {
    int total = 0;
    for (int py = 0; py < HEIGHT; py++) {
        for (int px = 0; px < WIDTH; px++) {
            float x0 = (float)px / WIDTH * 3.5f - 2.5f;
            float y0 = (float)py / HEIGHT * 2.0f - 1.0f;
            float x = 0.0f, y = 0.0f;
            int iter = 0;
            while (x * x + y * y <= 4.0f && iter < MAX_ITER) {
                float xtemp = x * x - y * y + x0;
                y = 2.0f * x * y + y0;
                x = xtemp;
                iter++;
            }
            pixels[py * WIDTH + px] = iter;
            total += iter;
        }
    }
    return total;
}

#ifndef __wasm__
#include <stdio.h>
#include <time.h>
int main(void) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int result = mandelbrot();
    clock_gettime(CLOCK_MONOTONIC, &end);
    double ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                (end.tv_nsec - start.tv_nsec) / 1000000.0;
    printf("mandelbrot: %.2f ms (checksum=%d)\n", ms, result);
    return 0;
}
#endif
