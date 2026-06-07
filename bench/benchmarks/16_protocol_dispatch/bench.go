package main

import "fmt"

type Computable interface {
	compute(x int64) int64
}

type Multiplier struct {
	factor int64
}

func (m Multiplier) compute(x int64) int64 {
	return m.factor * x
}

func main() {
	n := 10000
	var c Computable = Multiplier{factor: 3}
	var sum int64
	for i := 0; i < n; i++ {
		sum += c.compute(int64(i))
	}
	fmt.Println(sum)
}
