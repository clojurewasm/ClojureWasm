package main

import "fmt"

type Node struct {
	val  int64
	next *Node
}

func main() {
	n := 10000
	var head *Node
	for i := 0; i < n; i++ {
		head = &Node{val: int64(i), next: head}
	}
	count := 0
	for cur := head; cur != nil; cur = cur.next {
		count++
	}
	fmt.Println(count)
}
