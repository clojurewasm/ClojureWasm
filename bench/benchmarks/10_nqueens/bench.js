function solve(n) {
    let solutions = 0;
    const queens = [];

    function safe(row, col) {
        for (let r = 0; r < queens.length; r++) {
            if (queens[r] === col || Math.abs(queens[r] - col) === row - r) {
                return false;
            }
        }
        return true;
    }

    function backtrack(row) {
        if (row === n) {
            solutions++;
            return;
        }
        for (let col = 0; col < n; col++) {
            if (safe(row, col)) {
                queens.push(col);
                backtrack(row + 1);
                queens.pop();
            }
        }
    }

    backtrack(0);
    return solutions;
}
console.log(solve(8));
