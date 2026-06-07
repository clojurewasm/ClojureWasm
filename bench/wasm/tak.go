package main

//export tak
func tak(x, y, z int32) int32 {
	if x <= y {
		return z
	}
	return tak(tak(x-1, y, z), tak(y-1, z, x), tak(z-1, x, y))
}

func main() {}
