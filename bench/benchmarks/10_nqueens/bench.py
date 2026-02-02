def solve(n):
    solutions = 0
    queens = []

    def safe(row, col):
        for r, qc in enumerate(queens):
            if qc == col or abs(qc - col) == row - r:
                return False
        return True

    def backtrack(row):
        nonlocal solutions
        if row == n:
            solutions += 1
            return
        for col in range(n):
            if safe(row, col):
                queens.append(col)
                backtrack(row + 1)
                queens.pop()

    backtrack(0)
    return solutions

print(solve(8))
