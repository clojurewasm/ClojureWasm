#include <stdio.h>
#include <stdlib.h>

struct Node {
    long val;
    struct Node *next;
};

int main(void) {
    int n = 10000;
    struct Node *head = NULL;
    for (int i = 0; i < n; i++) {
        struct Node *node = malloc(sizeof(struct Node));
        node->val = i;
        node->next = head;
        head = node;
    }

    long count = 0;
    struct Node *cur = head;
    while (cur) {
        count++;
        struct Node *tmp = cur;
        cur = cur->next;
        free(tmp);
    }
    printf("%ld\n", count);
    return 0;
}
