package main

//go:noinline
//export arith_loop
func arith_loop(n int32) int64 {
	var sum int64
	for i := int32(0); i < n; i++ {
		sum += int64(i)
	}
	return sum
}

// arith_bench runs arith_loop `iterations` times. Returns the last result.
//export arith_bench
func arith_bench(n int32, iterations int32) int64 {
	var result int64
	for i := int32(0); i < iterations; i++ {
		result = arith_loop(n + int32(result&1))
	}
	return result
}

func main() {}
