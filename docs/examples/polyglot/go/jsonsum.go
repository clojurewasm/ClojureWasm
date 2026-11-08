// A Go program as a WASI command for cljw's wasm/run.
//
// Go's WebAssembly target is a full program (a WASI command with a runtime,
// a GC and the standard library), not a bag of scalar exports, so the
// natural boundary is the one a process has: argv, environment, stdin and
// stdout. cljw runs it with `wasm/run` and gets `{:out :err :exit}` back.
//
// Build (stdlib only, no cgo, no network):
//   GOOS=wasip1 GOARCH=wasm go build -o jsonsum.wasm jsonsum.go
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	var xs []float64
	if err := json.NewDecoder(os.Stdin).Decode(&xs); err != nil {
		fmt.Fprintln(os.Stderr, "jsonsum: stdin is not a JSON array of numbers:", err)
		os.Exit(2)
	}
	sum := 0.0
	for _, x := range xs {
		sum += x
	}
	out := map[string]any{
		"n":    len(xs),
		"sum":  sum,
		"args": os.Args[1:],
		"mode": os.Getenv("MODE"),
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		os.Exit(1)
	}
}
