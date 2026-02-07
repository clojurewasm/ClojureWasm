#include <stdio.h>

enum OpType { ADD, MUL, SUB };

typedef struct {
    enum OpType type;
    long a;
    long b;
} Op;

long process(Op *op) {
    switch (op->type) {
        case ADD: return op->a + op->b;
        case MUL: return op->a * op->b;
        case SUB: return op->a - op->b;
    }
    return 0;
}

int main(void) {
    int n = 10000;
    Op data = {ADD, 3, 4};
    long sum = 0;
    for (int i = 0; i < n; i++) {
        sum += process(&data);
    }
    printf("%ld\n", sum);
    return 0;
}
