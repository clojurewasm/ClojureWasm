package main

//go:noinline
//export gcd
func gcd(a, b int32) int32 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

func main() {}
