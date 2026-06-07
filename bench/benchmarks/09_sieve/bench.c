#include <stdio.h>
#include <stdlib.h>

/* Filter-based sieve: match Clojure's functional approach */
int main(void) {
    int limit = 1000;
    int *cand = malloc((limit - 1) * sizeof(int));
    int len = 0;
    for (int i = 2; i <= limit; i++) cand[len++] = i;

    int count = 0;
    while (len > 0) {
        int p = cand[0];
        count++;
        int new_len = 0;
        for (int i = 1; i < len; i++) {
            if (cand[i] % p != 0)
                cand[new_len++] = cand[i];
        }
        len = new_len;
    }

    printf("%d\n", count);
    free(cand);
    return 0;
}
