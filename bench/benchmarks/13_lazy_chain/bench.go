package main

import "fmt"

func main() {
	var sum int64
	count := 0
	for i := int64(0); count < 10000; i++ {
		v := i * 3
		if v%2 == 0 {
			sum += v
			count++
		}
	}
	fmt.Println(sum)
}
