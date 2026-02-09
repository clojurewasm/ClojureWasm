package main

import "fmt"

const (
	ADD = iota
	MUL
	SUB
)

type Op struct {
	opType int
	a, b   int64
}

func process(op *Op) int64 {
	switch op.opType {
	case ADD:
		return op.a + op.b
	case MUL:
		return op.a * op.b
	case SUB:
		return op.a - op.b
	}
	return 0
}

func main() {
	n := 10000
	op := &Op{ADD, 3, 4}
	var sum int64
	for i := 0; i < n; i++ {
		sum += process(op)
	}
	fmt.Println(sum)
}
