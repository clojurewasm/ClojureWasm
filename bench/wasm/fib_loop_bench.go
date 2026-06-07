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

// fib_loop_bench runs fib_loop(n) `iterations` times, varying input
// slightly to prevent constant folding. Returns the last result.
//export fib_loop_bench
func fib_loop_bench(n int32, iterations int32) int32 {
	var result int32
	for i := int32(0); i < iterations; i++ {
		result = fib_loop(n + (result & 1))
	}
	return result
}

func main() {}
