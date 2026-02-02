#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int n = 10000;
    long *vec = malloc(n * sizeof(long));
    for (int i = 0; i < n; i++) vec[i] = i;

    long sum = 0;
    for (int i = 0; i < n; i++) sum += vec[i];

    printf("%ld\n", sum);
    free(vec);
    return 0;
}
