#include <stdio.h>

int main(void) {
    long sum = 0;
    int count = 0;
    for (long i = 0; count < 10000; i++) {
        long v = i * 3;
        if (v % 2 == 0) {
            sum += v;
            count++;
        }
    }
    printf("%ld\n", sum);
    return 0;
}
