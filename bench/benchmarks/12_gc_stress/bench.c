#include <stdio.h>
#include <stdlib.h>

typedef struct { long a; long b; long c; } Triple;

int main(void) {
    int n = 100000;
    long sum = 0;
    for (int i = 0; i < n; i++) {
        Triple *m = malloc(sizeof(Triple));
        m->a = i;
        m->b = i + 1;
        m->c = i + 2;
        sum += m->b;
        free(m);
    }
    printf("%ld\n", sum);
    return 0;
}
