#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

/* Hash map allocation to match Clojure's {:a i :b (+ i 1) :c (+ i 2)} */
#define CAPACITY 8

typedef struct { const char *key; long val; bool used; } Entry;

static unsigned hash_str(const char *s) {
    unsigned h = 5381;
    while (*s) h = h * 33 + (unsigned char)*s++;
    return h;
}

static void put(Entry *t, const char *key, long val) {
    unsigned idx = hash_str(key) & (CAPACITY - 1);
    while (t[idx].used && strcmp(t[idx].key, key) != 0)
        idx = (idx + 1) & (CAPACITY - 1);
    t[idx].key = key;
    t[idx].val = val;
    t[idx].used = true;
}

static long get(Entry *t, const char *key) {
    unsigned idx = hash_str(key) & (CAPACITY - 1);
    while (t[idx].used) {
        if (strcmp(t[idx].key, key) == 0) return t[idx].val;
        idx = (idx + 1) & (CAPACITY - 1);
    }
    return 0;
}

int main(void) {
    int n = 100000;
    long sum = 0;
    for (int i = 0; i < n; i++) {
        Entry *m = calloc(CAPACITY, sizeof(Entry));
        put(m, "a", i);
        put(m, "b", i + 1);
        put(m, "c", i + 2);
        sum += get(m, "b");
        free(m);
    }
    printf("%ld\n", sum);
    return 0;
}
