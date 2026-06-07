package main

import "fmt"

func main() {
	n := 1000
	m := make(map[int]int64, n)
	for i := 0; i < n; i++ {
		m[i] = int64(i)
	}
	var sum int64
	for i := 0; i < n; i++ {
		sum += m[i]
	}
	fmt.Println(sum)
}
