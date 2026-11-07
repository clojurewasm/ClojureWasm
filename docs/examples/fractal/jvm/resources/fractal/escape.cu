// Escape-time kernels for fractal.renderer.cuda, compiled at run time by NVRTC.
// One thread per pixel. Same operation order as fractal.renderer.oracle/escape;
// compiled with --fmad=false so the fp64 kernel rounds exactly like the JVM.
// Writes the EscapeField only (count and |z|^2); the palette runs on the host.

#define ESCAPE_BODY(REAL)                                                       \
  int x = blockIdx.x * blockDim.x + threadIdx.x;                                \
  int y = blockIdx.y * blockDim.y + threadIdx.y;                                \
  if (x >= w || y >= h) return;                                                 \
  REAL cr = (REAL)cx + ((REAL)x - (REAL)w / (REAL)2.0) * (REAL)scale;            \
  REAL ci = (REAL)cy + ((REAL)y - (REAL)h / (REAL)2.0) * (REAL)scale;            \
  REAL zr = 0, zi = 0;                                                          \
  int n = 0;                                                                    \
  while (n < limit && zr * zr + zi * zi <= (REAL)4.0) {                         \
    REAL next = zr * zr - zi * zi + cr;                                         \
    zi = ((REAL)2.0 * zr) * zi + ci;                                            \
    zr = next;                                                                  \
    n++;                                                                        \
  }                                                                             \
  counts[y * w + x] = n;                                                        \
  mag2[y * w + x] = (double)(zr * zr + zi * zi);

extern "C" __global__ void escape_f64(int* counts, double* mag2, int w, int h,
                                      double cx, double cy, double scale, int limit) {
  ESCAPE_BODY(double)
}

extern "C" __global__ void escape_f32(int* counts, double* mag2, int w, int h,
                                      double cx, double cy, double scale, int limit) {
  ESCAPE_BODY(float)
}
