package main

import "fmt"

func main() {
	n := 10000
	var sum int64
	for i := 0; i < n; i++ {
		v := int64(i) * 3
		if v%2 == 0 {
			sum += v
		}
	}
	fmt.Println(sum)
}
