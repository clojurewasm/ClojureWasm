package main

import "fmt"

type Record struct {
	id     int
	value  int64
	active bool
}

func main() {
	n := 10000
	records := make([]Record, n)
	for i := 0; i < n; i++ {
		records[i] = Record{
			id:     i,
			value:  int64(i) * 2,
			active: i%3 == 0,
		}
	}
	var sum int64
	for _, r := range records {
		if r.active {
			sum += r.value
		}
	}
	fmt.Println(sum)
}
