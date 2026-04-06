FROM python:3.14-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSfL https://github.com/hatoo/oha/releases/download/v1.14.0/oha-linux-arm64 \
    -o /usr/local/bin/oha && chmod +x /usr/local/bin/oha

WORKDIR /bench
