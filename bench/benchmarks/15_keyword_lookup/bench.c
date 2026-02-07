#include <stdio.h>

typedef struct {
    const char *name;
    int age;
    const char *city;
    int score;
    int level;
} Record;

int main(void) {
    int n = 100000;
    Record m = {"Alice", 30, "NYC", 95, 5};
    long sum = 0;
    for (int i = 0; i < n; i++) {
        sum += m.score;
    }
    printf("%ld\n", sum);
    return 0;
}
