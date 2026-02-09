package main

//export arith_loop
func arith_loop(n int32) int64 {
	var sum int64
	for i := int32(0); i < n; i++ {
		sum += int64(i)
	}
	return sum
}

func main() {}
