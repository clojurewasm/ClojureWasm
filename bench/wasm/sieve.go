package main

import "unsafe"

// Use a fixed region of wasm linear memory as scratch space.
// Offset 1024 onwards (first 1024 bytes reserved for stack/globals).
const scratchOffset = 1024

//export sieve
func sieve(n int32) int32 {
	// Use raw memory pointer for the flags array
	base := unsafe.Pointer(uintptr(scratchOffset))

	// Initialize: set all bytes to 1 (prime candidate)
	for i := int32(2); i < n; i++ {
		*(*byte)(unsafe.Add(base, uintptr(i))) = 1
	}
	// Clear 0 and 1
	*(*byte)(unsafe.Add(base, 0)) = 0
	*(*byte)(unsafe.Add(base, 1)) = 0

	// Sieve
	for i := int32(2); i*i < n; i++ {
		if *(*byte)(unsafe.Add(base, uintptr(i))) != 0 {
			for j := i * i; j < n; j += i {
				*(*byte)(unsafe.Add(base, uintptr(j))) = 0
			}
		}
	}

	// Count primes
	count := int32(0)
	for i := int32(2); i < n; i++ {
		if *(*byte)(unsafe.Add(base, uintptr(i))) != 0 {
			count++
		}
	}
	return count
}

func main() {}
