#include <stdio.h>

int main(void) {
    int n = 10000;
    long counter = 0;
    for (int i = 0; i < n; i++) {
        counter = counter + 1;
    }
    printf("%ld\n", counter);
    return 0;
}
