#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int id;
    long value;
    int active;
} Record;

int main(void) {
    int n = 10000;
    Record *records = malloc(n * sizeof(Record));
    for (int i = 0; i < n; i++) {
        records[i].id = i;
        records[i].value = (long)i * 2;
        records[i].active = (i % 3 == 0);
    }

    long sum = 0;
    for (int i = 0; i < n; i++) {
        if (records[i].active) {
            sum += records[i].value;
        }
    }
    printf("%ld\n", sum);
    free(records);
    return 0;
}
