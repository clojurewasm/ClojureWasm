package main

//go:noinline
//export tak
func tak(x, y, z int32) int32 {
	if x <= y {
		return z
	}
	return tak(tak(x-1, y, z), tak(y-1, z, x), tak(z-1, x, y))
}

// tak_bench runs tak `iterations` times, varying input slightly
// to prevent constant folding. Returns the last result.
//export tak_bench
func tak_bench(x, y, z, iterations int32) int32 {
	var result int32
	for i := int32(0); i < iterations; i++ {
		result = tak(x+(result&1), y, z)
	}
	return result
}

func main() {}
