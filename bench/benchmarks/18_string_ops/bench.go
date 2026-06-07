package main

import (
	"fmt"
	"strconv"
)

func main() {
	n := 100000
	var sum int64
	for i := 0; i < n; i++ {
		s := strconv.Itoa(i)
		sum += int64(len(s))
	}
	fmt.Println(sum)
}
