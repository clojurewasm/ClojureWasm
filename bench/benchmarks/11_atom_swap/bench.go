package main

import "fmt"

func main() {
	n := 10000
	counter := 0
	for i := 0; i < n; i++ {
		counter++
	}
	fmt.Println(counter)
}
