/* Interim shim: re-export a jolt library's entry points as named symbols.
 *
 * A jolt --library build exposes only jolt_library_init and jolt_lookup;
 * `add`, `mandel`, `hive_call` and `hive_free` are function pointers handed
 * back by jolt_lookup, not dynamic symbols. cljw.ffi calls by name, so this
 * shim owns the lookup and forwards. It initialises the jolt runtime on the
 * first call, so a host that knows nothing about jolt (hive_call.clj) works.
 *
 * Drop it once cljw.ffi can call an address (card CLJW-FFI-CALL-ADDRESS).
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

int jolt_library_init(int argc, char **argv);
void *jolt_lookup(const char *name);

static int (*p_add)(int, int);
static int (*p_mandel)(double, double, int);
static char *(*p_hive_call)(const char *, const char *);
static void (*p_hive_free)(char *);
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void *need(const char *name) {
  void *p = jolt_lookup(name);
  if (!p) { fprintf(stderr, "jolt shim: no export %s\n", name); abort(); }
  return p;
}

static void boot(void) {
  if (jolt_library_init(0, NULL) != 0) { fprintf(stderr, "jolt shim: init failed\n"); abort(); }
  p_add = need("add");
  p_mandel = need("mandel");
  p_hive_call = need("hive_call");
  p_hive_free = need("hive_free");
}

int shim_init(void) { pthread_once(&once, boot); return 0; }
int add(int a, int b) { shim_init(); return p_add(a, b); }
int mandel(double cr, double ci, int max) { shim_init(); return p_mandel(cr, ci, max); }
char *hive_call(const char *op, const char *json) { shim_init(); return p_hive_call(op, json); }
void hive_free(char *p) { shim_init(); p_hive_free(p); }
