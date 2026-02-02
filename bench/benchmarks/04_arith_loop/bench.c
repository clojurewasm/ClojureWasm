#include <stdio.h>

int main(void) {
    long n = 1000000;
    long sum = 0;
    for (long i = 0; i < n; i++) {
        sum += i;
    }
    printf("%ld\n", sum);
    return 0;
}
