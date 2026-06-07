package main

import "fmt"

func main() {
	limit := 1000
	cand := make([]int, 0, limit)
	for i := 2; i <= limit; i++ {
		cand = append(cand, i)
	}

	count := 0
	for len(cand) > 0 {
		p := cand[0]
		count++
		next := cand[:0]
		for _, v := range cand[1:] {
			if v%p != 0 {
				next = append(next, v)
			}
		}
		cand = next
	}

	fmt.Println(count)
}
