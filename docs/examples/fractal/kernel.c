/* Mandelbrot RGBA8 kernel in C, freestanding with no imports.
 * Same ABI and pixel math as kernel.zig; see README.md "The kernel ABI".
 * Build from the repository root (clang 21):
 * clang --target=wasm32 -O3 -nostdlib -fno-builtin -Wl,--no-entry -Wl,--strip-all -o docs/examples/fractal/kernel_c.wasm docs/examples/fractal/kernel.c
 * log2 is computed locally (no libm in freestanding wasm), so palette bytes may
 * differ from kernel.zig by one level; iteration totals are exact. */

#include <stdint.h>

#define CAPACITY (1024 * 1024)
#define EXPORT(name) __attribute__((export_name(name)))

static uint8_t framebuffer[CAPACITY * 4];
static double view_cx = -0.5;
static double view_cy = 0.0;
static double view_scale = 3.5 / 512.0;

static int finite(double x) { return x - x == 0.0; }

/* log2 for x >= 1: split exponent and mantissa, then 2*atanh series. */
static double log2_pos(double x) {
  union { double d; uint64_t u; } v = { x };
  int64_t e = (int64_t)((v.u >> 52) & 0x7ff) - 1023;
  v.u = (v.u & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL;
  double m = v.d;
  if (m > 1.4142135623730951) { m *= 0.5; e += 1; }
  double s = (m - 1.0) / (m + 1.0);
  double s2 = s * s;
  double series = 1.0 + s2 * (1.0 / 3 + s2 * (1.0 / 5 + s2 * (1.0 / 7 + s2 * (1.0 / 9 +
                  s2 * (1.0 / 11 + s2 * (1.0 / 13 + s2 * (1.0 / 15 + s2 * (1.0 / 17 +
                  s2 * (1.0 / 19 + s2 * (1.0 / 21))))))))));
  return (double)e + 2.0 * s * series * 1.4426950408889634;
}

EXPORT("set_view") int32_t set_view(double cx, double cy, double scale) {
  view_cx = cx;
  view_cy = cy;
  view_scale = scale;
  return finite(cx) && finite(cy) && finite(scale) ? 0 : -1;
}

EXPORT("fb_ptr") int32_t fb_ptr(void) { return (int32_t)(uintptr_t)framebuffer; }
EXPORT("fb_cap") int32_t fb_cap(void) { return CAPACITY; }

static int valid(int32_t w, int32_t h, int32_t max_iter) {
  return w > 0 && h > 0 && w <= CAPACITY && h <= CAPACITY &&
         (int64_t)w * h <= CAPACITY && max_iter > 0 &&
         finite(view_cx) && finite(view_cy) && finite(view_scale);
}

static void color(uint32_t pixel, uint32_t n, uint32_t limit, double magnitude) {
  uint8_t *out = &framebuffer[pixel * 4];
  out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 255;
  if (n == limit) return;
  double bounded = finite(magnitude) ? (magnitude > 4.000001 ? magnitude : 4.000001) : 1.0e300;
  double smooth = (double)n + 1.0 - log2_pos(log2_pos(bounded) * 0.5);
  double phase = smooth * 0.025;
  for (int channel = 0; channel < 3; channel++) {
    double t = phase + (double)channel / 3.0;
    double wave = 1.0 - __builtin_fabs(2.0 * (t - __builtin_floor(t)) - 1.0);
    out[channel] = (uint8_t)(wave * 255.0);
  }
}

EXPORT("render") int64_t render(int32_t w, int32_t h, int32_t max_iter) {
  if (!valid(w, h, max_iter)) return -1;
  const double cx = view_cx, cy = view_cy, scale = view_scale;
  const uint32_t limit = (uint32_t)(max_iter < (1 << 26) - 1 ? max_iter : (1 << 26) - 1);
  int64_t total = 0;
  for (uint32_t y = 0; y < (uint32_t)h; y++) {
    const double ci = cy + ((double)y - (double)h / 2.0) * scale;
    for (uint32_t x = 0; x < (uint32_t)w; x++) {
      const double cr = cx + ((double)x - (double)w / 2.0) * scale;
      double zr = 0.0, zi = 0.0;
      uint32_t n = 0;
      while (n < limit && zr * zr + zi * zi <= 4.0) {
        double next = zr * zr - zi * zi + cr;
        zi = (2.0 * zr) * zi + ci;
        zr = next;
        n++;
      }
      total += n;
      color(y * (uint32_t)w + x, n, limit, zr * zr + zi * zi);
    }
  }
  return total;
}

/* Scalar twin so every kernel answers the same export set. */
EXPORT("render_simd") int64_t render_simd(int32_t w, int32_t h, int32_t max_iter) {
  return render(w, h, max_iter);
}
