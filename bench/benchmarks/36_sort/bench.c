#include <stdio.h>
#include <stdlib.h>

static int cmp(const void *a, const void *b) { return (*(int *)a) - (*(int *)b); }

int main(void) {
    int n = 5000;
    int *v = malloc(n * sizeof(int));
    long total = 0;
    for (int it = 0; it < 5; it++) {
        for (int i = 0; i < n; i++) v[i] = n - i;
        qsort(v, n, sizeof(int), cmp);
        long s = 0;
        for (int i = 0; i < 100; i++) s += v[i];
        total = s;
    }
    printf("%ld\n", total);
    free(v);
    return 0;
}
