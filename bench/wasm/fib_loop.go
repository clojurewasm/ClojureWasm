package main

//go:noinline
//export fib_loop
func fib_loop(n int32) int32 {
	var a, b int32 = 0, 1
	for i := int32(0); i < n; i++ {
		a, b = b, a+b
	}
	return a
}

func main() {}
