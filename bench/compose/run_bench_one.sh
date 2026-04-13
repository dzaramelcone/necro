#!/bin/bash
# Bench one server in a fresh container.
# Args: $1 = display name, $2 = setup script (run before starting), $3 = start command, $4 = connections (default 256)
# Uses identical protocol for every server: primer (c=8 4s) + warmup (c=$CONNS 3s) + bench (c=$CONNS 10s).

set -u

NAME="$1"
SETUP="$2"
START="$3"
CONNS="${4:-256}"

cd /bench

# Per-server setup (mostly necro / go builds)
eval "$SETUP"

# Start server in background
eval "$START" > /tmp/srv.log 2>&1 &
SRV_PID=$!

# Wait for server to bind
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sS -o /tmp/body -w "" http://127.0.0.1:8080/ 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if ! curl -sS -o /tmp/body -w "" http://127.0.0.1:8080/ 2>/dev/null; then
    echo "FAILED to start $NAME"
    tail -10 /tmp/srv.log
    kill -9 $SRV_PID 2>/dev/null
    exit 1
fi

BODY=$(cat /tmp/body)

# Primer: c=8, 4s
wrk -t8 -c8 -d4s http://127.0.0.1:8080/ > /dev/null 2>&1

# Warmup: c=$CONNS, 3s
wrk -t8 -c"$CONNS" -d3s http://127.0.0.1:8080/ > /dev/null 2>&1

# Bench: c=$CONNS, 10s - only this is reported
echo "========== $NAME (c=$CONNS) =========="
echo "body: $BODY"
wrk -t8 -c"$CONNS" -d10s http://127.0.0.1:8080/ 2>&1 | grep -E "Requests/sec|Latency|Socket errors"

kill -9 $SRV_PID 2>/dev/null
