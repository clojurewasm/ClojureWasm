package main

import "fmt"

func main() {
	n := 100000
	m := map[string]int64{
		"name":  0,
		"age":   30,
		"city":  0,
		"score": 95,
		"level": 5,
	}
	var sum int64
	for i := 0; i < n; i++ {
		sum += m["score"]
	}
	fmt.Println(sum)
}
