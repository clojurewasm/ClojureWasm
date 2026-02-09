package main

import "fmt"

func tak(x, y, z int) int {
	if x <= y {
		return z
	}
	return tak(tak(x-1, y, z), tak(y-1, z, x), tak(z-1, x, y))
}

func main() {
	fmt.Println(tak(18, 12, 6))
}
