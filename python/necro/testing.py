import importlib
import json as _json
import os
import socket
import sys
import threading
import time


class TestResponse:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self._body = body

    def json(self):
        return _json.loads(self._body)

    def text(self):
        return self._body.decode()

    def header(self, name):
        return self.headers.get(name.lower())


class TestClient:
    __test__ = False

    def __init__(self, app_file, port=0):
        self._app_file = app_file
        self.port = port or _find_free_port()
        self.headers = {}
        self._thread = None

    def __enter__(self):
        self._start()
        return self

    def __exit__(self, *args):
        self._stop()

    def _start(self):
        from necro import core

        app_path = os.path.abspath(self._app_file)
        app_dir = os.path.dirname(app_path)
        module_name = os.path.splitext(os.path.basename(app_path))[0]

        if app_dir not in sys.path:
            sys.path.insert(0, app_dir)
        importlib.import_module(module_name)

        from necro import __version__
        self._thread = threading.Thread(
            target=core.run,
            args=("127.0.0.1", self.port, 1, module_name, app_dir, 2048, __version__),
            daemon=True,
        )
        self._thread.start()

        for _ in range(50):
            try:
                s = socket.create_connection(("127.0.0.1", self.port), timeout=0.1)
                s.close()
                return
            except (ConnectionRefusedError, OSError):
                time.sleep(0.1)

        raise RuntimeError("server did not start")

    def _stop(self):
        if self._thread is None:
            return
        from necro import core
        core.shutdown()
        # Nudge the event loop so it wakes from any blocking wait and notices
        # the shutdown flag.
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.5):
                pass
        except OSError:
            pass
        self._thread.join(timeout=2)
        self._thread = None

    def send_raw(self, data):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            s.sendall(data)
            return _recv_response(s)
        finally:
            s.close()

    def send_raw_keepalive(self, data):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        s.sendall(data)
        return s

    def get(self, path, *, headers=None):
        return self._request("GET", path, headers=headers)

    def post(self, path, *, body=None, json=None, headers=None):
        return self._request("POST", path, body=body, json=json, headers=headers)

    def put(self, path, *, body=None, json=None, headers=None):
        return self._request("PUT", path, body=body, json=json, headers=headers)

    def delete(self, path, *, headers=None):
        return self._request("DELETE", path, headers=headers)

    def patch(self, path, *, body=None, json=None, headers=None):
        return self._request("PATCH", path, body=body, json=json, headers=headers)

    def _request(self, method, path, *, body=None, json=None, headers=None):
        all_headers = {**self.headers, **(headers or {})}
        raw_body = b""
        if json is not None:
            raw_body = _json.dumps(json).encode()
            all_headers.setdefault("Content-Type", "application/json")
        elif body is not None:
            raw_body = body if isinstance(body, bytes) else body.encode()

        req = f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n"
        if raw_body:
            req += f"Content-Length: {len(raw_body)}\r\n"
        for k, v in all_headers.items():
            req += f"{k}: {v}\r\n"
        req += "Connection: close\r\n\r\n"

        raw = self.send_raw(req.encode() + raw_body)
        return _parse_response(raw)


def _find_free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _recv_response(s):
    response = b""
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        response += chunk
        if b"\r\n\r\n" in response:
            head, _, body_start = response.partition(b"\r\n\r\n")
            headers = _parse_headers(head)
            cl = int(headers.get("content-length", 0))
            if len(body_start) >= cl:
                return head + b"\r\n\r\n" + body_start[:cl]
    return response


def _parse_headers(head):
    headers = {}
    for line in head.decode().split("\r\n")[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower()] = v
    return headers


def _parse_response(raw):
    if not raw:
        return TestResponse(0, {}, b"")
    head, _, body = raw.partition(b"\r\n\r\n")
    first_line = head.split(b"\r\n")[0]
    parts = first_line.split(b" ", 2)
    status = int(parts[1]) if len(parts) >= 2 else 0
    headers = _parse_headers(head)
    return TestResponse(status, headers, body)
