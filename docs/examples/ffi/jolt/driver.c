/* C host for a jolt --library build: dlopen, init, lookup, call, timed.
 *
 *   build/driver build/libdemo.so
 */
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>

static double ms(struct timespec a, struct timespec b) {
  return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

int main(int argc, char **argv) {
  struct timespec t0, t1, t2, t3;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  void *h = dlopen(argc > 1 ? argv[1] : "./libdemo.so", RTLD_NOW);
  if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  int (*init)(int, char **) = dlsym(h, "jolt_library_init");
  void *(*lookup)(const char *) = dlsym(h, "jolt_lookup");
  clock_gettime(CLOCK_MONOTONIC, &t1);
  int rc = init(0, NULL);
  clock_gettime(CLOCK_MONOTONIC, &t2);
  int (*add)(int, int) = lookup("add");
  int (*mandel)(double, double, int) = lookup("mandel");
  printf("init=%d add(2,40)=%d mandel(-0.75,0.1,1000)=%d\n", rc, add(2, 40), mandel(-0.75, 0.1, 1000));
  long sum = 0;
  for (int y = 0; y < 200; y++)
    for (int x = 0; x < 300; x++)
      sum += mandel(-2.0 + 3.0 * x / 300, -1.0 + 2.0 * y / 200, 255);
  clock_gettime(CLOCK_MONOTONIC, &t3);
  printf("grid 300x200 sum=%ld\n", sum);
  printf("dlopen %.2f ms, init %.2f ms, grid %.2f ms\n", ms(t0, t1), ms(t1, t2), ms(t2, t3));
  return 0;
}
