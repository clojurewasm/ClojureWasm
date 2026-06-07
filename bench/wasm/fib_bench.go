package main

//go:noinline
//export fib
func fib(n int32) int32 {
	if n <= 1 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

// fib_bench runs fib(n) `iterations` times, varying input slightly
// to prevent constant folding. Returns the last result.
//export fib_bench
func fib_bench(n int32, iterations int32) int32 {
	var result int32
	for i := int32(0); i < iterations; i++ {
		// Vary input by +0 or +1 based on low bit of accumulated result
		result = fib(n + (result & 1))
	}
	return result
}

func main() {}
