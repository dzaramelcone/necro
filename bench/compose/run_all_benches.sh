#!/usr/bin/env bash
# Orchestrator: run each server bench in its own fresh docker container.
# Same protocol for every server: primer + warmup + bench, c=256, wrk -t8 -d10s.

set -u

cd "$(dirname "$0")"

# Each entry: name | setup | start
BENCHES=(
  "nginx 7-worker (C)|sed -e 's/^worker_processes .*/worker_processes 7;/' -e 's/listen 8081/listen 8080/' /bench/nginx.conf > /tmp/nginx.conf|nginx -c /tmp/nginx.conf"
  "Go net/http stdlib (GOMAXPROCS=7)|mkdir -p /tmp/goserver && cp /bench/main.go /tmp/goserver/ && ( cd /tmp/goserver && go build -o goserver main.go )|/tmp/goserver/goserver -addr :8080 -procs 7"
  "fasthttp (GOMAXPROCS=7)|mkdir -p /tmp/fasthttp && cp /bench/fasthttp_main.go /tmp/fasthttp/main.go && ( cd /tmp/fasthttp && go mod init bench >/dev/null 2>&1 && go get github.com/valyala/fasthttp >/dev/null 2>&1 && go build -o fasthttp_server main.go )|/tmp/fasthttp/fasthttp_server -addr :8080 -procs 7"
  "uvicorn + bare ASGI (7 workers)||uvicorn bench_asgi_raw:app --host 0.0.0.0 --port 8080 --workers 7 --no-access-log --loop uvloop --http httptools"
  "uvicorn + litestar (7 workers)||uvicorn bench_litestar:app --host 0.0.0.0 --port 8080 --workers 7 --no-access-log --loop uvloop --http httptools"
  "uvicorn + starlette (7 workers)||uvicorn bench_starlette:app --host 0.0.0.0 --port 8080 --workers 7 --no-access-log --loop uvloop --http httptools"
  "uvicorn + fastapi (7 workers)||uvicorn bench_fastapi:app --host 0.0.0.0 --port 8080 --workers 7 --no-access-log --loop uvloop --http httptools"
  "granian + bare ASGI (7 workers)||granian --interface asgi --host 0.0.0.0 --port 8080 --workers 7 --log-level error --http 1 --no-ws bench_asgi_raw:app"
  "granian + fastapi (7 workers)||granian --interface asgi --host 0.0.0.0 --port 8080 --workers 7 --log-level error --http 1 --no-ws bench_fastapi:app"
  "necro 7T (Zig)|cp -r /bench/necro_root /tmp/necro_pkg && ln -sf /bench/necro_lib/libcore.so /tmp/necro_pkg/necro/core.cpython-314-aarch64-linux-gnu.so|PYTHONPATH=/tmp/necro_pkg python3 -m necro.cli host bench_plaintext --threads 7"
)

for entry in "${BENCHES[@]}"; do
  IFS='|' read -r name setup start <<< "$entry"
  docker compose run --rm --no-deps bench bash /bench/run_bench_one.sh "$name" "$setup" "$start"
  sleep 1
done
