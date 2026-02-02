#include <stdio.h>
#include <stdlib.h>

// Simple hash map simulation with array (keys are 0..n-1)
int main(void) {
    int n = 1000;
    long *map = calloc(n, sizeof(long));
    for (int i = 0; i < n; i++) map[i] = i;

    long sum = 0;
    for (int i = 0; i < n; i++) sum += map[i];

    printf("%ld\n", sum);
    free(map);
    return 0;
}
