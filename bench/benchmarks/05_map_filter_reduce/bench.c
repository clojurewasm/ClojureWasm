#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int n = 10000;
    long *arr = malloc(n * sizeof(long));
    for (int i = 0; i < n; i++) arr[i] = i;

    // map: x*x
    for (int i = 0; i < n; i++) arr[i] = arr[i] * arr[i];

    // filter even + reduce
    long sum = 0;
    for (int i = 0; i < n; i++) {
        if (arr[i] % 2 == 0) sum += arr[i];
    }
    printf("%ld\n", sum);
    free(arr);
    return 0;
}
