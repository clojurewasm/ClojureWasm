#include <stdio.h>

typedef struct {
    long (*compute)(void *self, long x);
    long factor;
} Computable;

long compute_impl(void *self, long x) {
    Computable *c = (Computable *)self;
    return c->factor * x;
}

int main(void) {
    int n = 10000;
    Computable m = {compute_impl, 3};
    long sum = 0;
    for (int i = 0; i < n; i++) {
        sum += m.compute(&m, i);
    }
    printf("%ld\n", sum);
    return 0;
}
