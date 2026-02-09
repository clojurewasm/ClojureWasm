package main

import "fmt"

func main() {
	n := 10000
	m := map[string]interface{}{
		"a": map[string]interface{}{
			"b": map[string]int64{
				"c": 0,
			},
		},
	}
	for i := 0; i < n; i++ {
		inner := m["a"].(map[string]interface{})["b"].(map[string]int64)
		inner["c"]++
	}
	result := m["a"].(map[string]interface{})["b"].(map[string]int64)["c"]
	fmt.Println(result)
}
