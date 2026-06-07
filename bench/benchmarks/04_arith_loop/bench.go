package main

import "fmt"

func main() {
	n := 1000000
	sum := 0
	for i := 0; i < n; i++ {
		sum += i
	}
	fmt.Println(sum)
}
