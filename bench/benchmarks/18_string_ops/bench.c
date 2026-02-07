#include <stdio.h>
#include <string.h>

int main(void) {
    int n = 100000;
    long sum = 0;
    char buf[32];
    for (int i = 0; i < n; i++) {
        snprintf(buf, sizeof(buf), "%d", i);
        sum += strlen(buf);
    }
    printf("%ld\n", sum);
    return 0;
}
