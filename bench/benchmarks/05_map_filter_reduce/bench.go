package main

import "fmt"

func main() {
	n := 10000
	arr := make([]int64, n)
	for i := range arr {
		arr[i] = int64(i)
	}
	// map: x*x
	for i := range arr {
		arr[i] = arr[i] * arr[i]
	}
	// filter even + reduce
	var sum int64
	for _, v := range arr {
		if v%2 == 0 {
			sum += v
		}
	}
	fmt.Println(sum)
}
