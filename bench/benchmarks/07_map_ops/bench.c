#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

/* Simple open-addressing hash map (int key -> long value) */
#define CAPACITY 2048

typedef struct { int key; long val; bool used; } Entry;

static void put(Entry *t, int key, long val) {
    unsigned idx = (unsigned)key * 2654435761u & (CAPACITY - 1);
    while (t[idx].used && t[idx].key != key)
        idx = (idx + 1) & (CAPACITY - 1);
    t[idx].key = key;
    t[idx].val = val;
    t[idx].used = true;
}

static long get(Entry *t, int key) {
    unsigned idx = (unsigned)key * 2654435761u & (CAPACITY - 1);
    while (t[idx].used) {
        if (t[idx].key == key) return t[idx].val;
        idx = (idx + 1) & (CAPACITY - 1);
    }
    return 0;
}

int main(void) {
    int n = 1000;
    Entry *map = calloc(CAPACITY, sizeof(Entry));
    for (int i = 0; i < n; i++) put(map, i, i);

    long sum = 0;
    for (int i = 0; i < n; i++) sum += get(map, i);

    printf("%ld\n", sum);
    free(map);
    return 0;
}
