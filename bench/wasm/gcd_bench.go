package main

//go:noinline
//export gcd
func gcd(a, b int32) int32 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

// gcd_bench runs gcd(a, b) `iterations` times, varying inputs
// to prevent constant folding. Returns the accumulated sum.
//export gcd_bench
func gcd_bench(a, b, iterations int32) int32 {
	var sum int32
	for i := int32(0); i < iterations; i++ {
		sum += gcd(a+i, b+i)
	}
	return sum
}

func main() {}
