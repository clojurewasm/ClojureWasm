package main

import "fmt"

const N = 8

var queens [N]int
var solutions int

func safe(row, col int) bool {
	for r := 0; r < row; r++ {
		if queens[r] == col ||
			queens[r]-col == r-row ||
			col-queens[r] == r-row {
			return false
		}
	}
	return true
}

func solve(row int) {
	if row == N {
		solutions++
		return
	}
	for col := 0; col < N; col++ {
		if safe(row, col) {
			queens[row] = col
			solve(row + 1)
		}
	}
}

func main() {
	solve(0)
	fmt.Println(solutions)
}
