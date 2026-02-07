package main

//export add
func add(a, b int32) int32 {
	return a + b
}

//export multiply
func multiply(a, b int32) int32 {
	return a * b
}

//export fibonacci
func fibonacci(n int32) int32 {
	if n <= 1 {
		return n
	}
	a, b := int32(0), int32(1)
	for i := int32(2); i <= n; i++ {
		a, b = b, a+b
	}
	return b
}

//export factorial
func factorial(n int32) int32 {
	result := int32(1)
	for i := int32(2); i <= n; i++ {
		result *= i
	}
	return result
}

//export gcd
func gcd(a, b int32) int32 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

//export is_prime
func is_prime(n int32) int32 {
	if n < 2 {
		return 0
	}
	for i := int32(2); i*i <= n; i++ {
		if n%i == 0 {
			return 0
		}
	}
	return 1
}

func main() {}
