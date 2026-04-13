package main

import (
	"flag"
	"log"
	"runtime"

	"github.com/valyala/fasthttp"
)

func main() {
	addr := flag.String("addr", ":8083", "listen address")
	procs := flag.Int("procs", 0, "GOMAXPROCS (0 = runtime default)")
	flag.Parse()

	if *procs > 0 {
		runtime.GOMAXPROCS(*procs)
	}

	body := []byte(`{"message":"Hello, World!"}`)
	h := func(ctx *fasthttp.RequestCtx) {
		ctx.SetContentType("application/json")
		ctx.SetBody(body)
	}

	server := &fasthttp.Server{
		Handler:               h,
		Name:                  "fasthttp",
		ReadBufferSize:        8192,
		WriteBufferSize:       8192,
		DisableHeaderNamesNormalizing: true,
	}

	log.Printf("fasthttp listening on %s, GOMAXPROCS=%d", *addr, runtime.GOMAXPROCS(0))
	if err := server.ListenAndServe(*addr); err != nil {
		log.Fatal(err)
	}
}
