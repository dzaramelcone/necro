package main

import (
	"flag"
	"log"
	"net/http"
	"runtime"
)

func main() {
	addr := flag.String("addr", ":8082", "listen address")
	procs := flag.Int("procs", 0, "GOMAXPROCS (0 = runtime default)")
	flag.Parse()

	if *procs > 0 {
		runtime.GOMAXPROCS(*procs)
	}

	body := []byte(`{"message":"Hello, World!"}`)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})

	log.Printf("Go net/http listening on %s, GOMAXPROCS=%d", *addr, runtime.GOMAXPROCS(0))
	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatal(err)
	}
}
