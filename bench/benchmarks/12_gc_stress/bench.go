package main

import "fmt"

func main() {
	n := 100000
	var sum int64
	for i := 0; i < n; i++ {
		m := map[string]int64{
			"a": int64(i),
			"b": int64(i + 1),
			"c": int64(i + 2),
		}
		sum += m["b"]
	}
	fmt.Println(sum)
}
