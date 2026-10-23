// SPDX-License-Identifier: EPL-2.0
// cljw.ffi suite fixture (ADR-0202). Compiled by test/clj/suites/ffi_test.clj
// with the system cc into a temporary shared library; never committed built.
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int add_i(int a, int b) { return a + b; }

long add_l(long a, long b) { return a + b; }

double scale(double x, long n) { return x * (double)n; }

// Each argument lands in its own decimal place, so a swapped register shows.
long mixed(long a, double b, long c, double d, long e, double f) {
    return (long)(a * 1 + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000);
}

int neg(void) { return -7; }

const char *greet(const char *name) {
    static char buf[256];
    snprintf(buf, sizeof buf, "hi %s", name ? name : "(null)");
    return buf;
}

char *dup_upper(const char *s) {
    size_t n = strlen(s);
    char *out = malloc(n + 1);
    for (size_t i = 0; i < n; i++) out[i] = (char)toupper((unsigned char)s[i]);
    out[n] = 0;
    return out;
}

void fixture_free(void *p) { free(p); }

long sum_bytes(const unsigned char *p, long n) {
    long s = 0;
    for (long i = 0; i < n; i++) s += p[i];
    return s;
}

void *null_ptr(void) { return NULL; }

long six_ints(long a, long b, long c, long d, long e, long f) {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f;
}

double eight_doubles(double a, double b, double c, double d, double e, double f, double g, double h) {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

int is_null(const char *s) { return s == NULL; }

// Primitive arrays passed as :pointer (ADR-0204): contiguous native storage.
double dot(const double *a, const double *b, long n) {
    double s = 0;
    for (long i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

long sum_i32(const int *p, long n) {
    long s = 0;
    for (long i = 0; i < n; i++) s += p[i];
    return s;
}

double sum_f32(const float *p, long n) {
    double s = 0;
    for (long i = 0; i < n; i++) s += p[i];
    return s;
}

void fill_i64(long *p, long n, long v) {
    for (long i = 0; i < n; i++) p[i] = v + i;
}

void bump_bytes(unsigned char *p, long n) {
    for (long i = 0; i < n; i++) p[i]++;
}
