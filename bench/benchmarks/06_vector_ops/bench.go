package main

import "fmt"

func main() {
	n := 10000
	vec := make([]int64, n)
	for i := range vec {
		vec[i] = int64(i)
	}
	var sum int64
	for _, v := range vec {
		sum += v
	}
	fmt.Println(sum)
}
