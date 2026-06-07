public class Bench {
    static final int N = 8;
    static int[] queens = new int[N];
    static int solutions = 0;

    static boolean safe(int row, int col) {
        for (int r = 0; r < row; r++) {
            if (queens[r] == col ||
                queens[r] - col == r - row ||
                col - queens[r] == r - row)
                return false;
        }
        return true;
    }

    static void solve(int row) {
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

    public static void main(String[] args) {
        solve(0);
        System.out.println(solutions);
    }
}
