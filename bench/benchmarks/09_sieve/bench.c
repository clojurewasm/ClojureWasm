#include <stdio.h>
#include <stdbool.h>

int main(void) {
    int limit = 1000;
    bool sieve[1001];
    for (int i = 0; i <= limit; i++) sieve[i] = true;
    sieve[0] = sieve[1] = false;

    for (int i = 2; i * i <= limit; i++) {
        if (sieve[i]) {
            for (int j = i * i; j <= limit; j += i)
                sieve[j] = false;
        }
    }

    int count = 0;
    for (int i = 2; i <= limit; i++) {
        if (sieve[i]) count++;
    }
    printf("%d\n", count);
    return 0;
}
