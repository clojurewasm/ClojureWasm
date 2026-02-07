#include <stdio.h>

typedef struct { long c; } LevelC;
typedef struct { LevelC b; } LevelB;
typedef struct { LevelB a; } LevelA;

int main(void) {
    int n = 10000;
    LevelA m = { .a = { .b = { .c = 0 } } };
    for (int i = 0; i < n; i++) {
        m.a.b.c++;
    }
    printf("%ld\n", m.a.b.c);
    return 0;
}
