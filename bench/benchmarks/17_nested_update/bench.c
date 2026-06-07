#include <stdio.h>
#include <string.h>
#include <stdbool.h>

/* Nested hash map update to match Clojure's (update-in m [:a :b :c] inc) */
#define CAPACITY 4

typedef struct { const char *key; long val; bool used; bool is_ptr; void *ptr; } Entry;

static unsigned hash_str(const char *s) {
    unsigned h = 5381;
    while (*s) h = h * 33 + (unsigned char)*s++;
    return h;
}

static Entry *find(Entry *t, const char *key) {
    unsigned idx = hash_str(key) & (CAPACITY - 1);
    while (t[idx].used) {
        if (strcmp(t[idx].key, key) == 0) return &t[idx];
        idx = (idx + 1) & (CAPACITY - 1);
    }
    return NULL;
}

static void put_val(Entry *t, const char *key, long val) {
    unsigned idx = hash_str(key) & (CAPACITY - 1);
    while (t[idx].used && strcmp(t[idx].key, key) != 0)
        idx = (idx + 1) & (CAPACITY - 1);
    t[idx].key = key;
    t[idx].val = val;
    t[idx].used = true;
    t[idx].is_ptr = false;
}

static void put_ptr(Entry *t, const char *key, void *ptr) {
    unsigned idx = hash_str(key) & (CAPACITY - 1);
    while (t[idx].used && strcmp(t[idx].key, key) != 0)
        idx = (idx + 1) & (CAPACITY - 1);
    t[idx].key = key;
    t[idx].ptr = ptr;
    t[idx].used = true;
    t[idx].is_ptr = true;
}

int main(void) {
    int n = 10000;
    /* Build nested map: {:a {:b {:c 0}}} */
    Entry level_c[CAPACITY] = {{0}};
    put_val(level_c, "c", 0);

    Entry level_b[CAPACITY] = {{0}};
    put_ptr(level_b, "b", level_c);

    Entry level_a[CAPACITY] = {{0}};
    put_ptr(level_a, "a", level_b);

    /* Navigate and update via hash lookup each iteration */
    for (int i = 0; i < n; i++) {
        Entry *ea = find(level_a, "a");
        Entry *eb = find((Entry *)ea->ptr, "b");
        Entry *ec = find((Entry *)eb->ptr, "c");
        ec->val++;
    }

    /* Read result via hash lookup */
    Entry *ra = find(level_a, "a");
    Entry *rb = find((Entry *)ra->ptr, "b");
    Entry *rc = find((Entry *)rb->ptr, "c");
    printf("%ld\n", rc->val);
    return 0;
}
