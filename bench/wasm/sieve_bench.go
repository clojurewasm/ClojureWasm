package main

import "unsafe"

const scratchOffset = 1024

//go:noinline
//export sieve
func sieve(n int32) int32 {
	base := unsafe.Pointer(uintptr(scratchOffset))

	for i := int32(2); i < n; i++ {
		*(*byte)(unsafe.Add(base, uintptr(i))) = 1
	}
	*(*byte)(unsafe.Add(base, 0)) = 0
	*(*byte)(unsafe.Add(base, 1)) = 0

	for i := int32(2); i*i < n; i++ {
		if *(*byte)(unsafe.Add(base, uintptr(i))) != 0 {
			for j := i * i; j < n; j += i {
				*(*byte)(unsafe.Add(base, uintptr(j))) = 0
			}
		}
	}

	count := int32(0)
	for i := int32(2); i < n; i++ {
		if *(*byte)(unsafe.Add(base, uintptr(i))) != 0 {
			count++
		}
	}
	return count
}

// sieve_bench runs sieve `iterations` times. Returns the last result.
//export sieve_bench
func sieve_bench(n int32, iterations int32) int32 {
	var result int32
	for i := int32(0); i < iterations; i++ {
		result = sieve(n + (result & 1))
	}
	return result
}

func main() {}
