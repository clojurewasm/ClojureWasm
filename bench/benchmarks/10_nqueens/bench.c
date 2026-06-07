#include <stdio.h>
#include <stdbool.h>

#define N 8

int queens[N];
int solutions = 0;

bool safe(int row, int col) {
    for (int r = 0; r < row; r++) {
        if (queens[r] == col ||
            queens[r] - col == r - row ||
            col - queens[r] == r - row)
            return false;
    }
    return true;
}

void solve(int row) {
    if (row == N) {
        solutions++;
        return;
    }
    for (int col = 0; col < N; col++) {
        if (safe(row, col)) {
            queens[row] = col;
            solve(row + 1);
        }
    }
}

int main(void) {
    solve(0);
    printf("%d\n", solutions);
    return 0;
}
