import os
import socket
import pytest
from necro.testing import TestClient

APP = os.path.join(os.path.dirname(__file__), "app.py")


@pytest.fixture(scope="module")
def client():
    with TestClient(APP) as c:
        yield c


def test_get_json(client):
    resp = client.get("/")
    assert resp.status == 200
    assert resp.json() == {"message": "hello"}


def test_get_text(client):
    resp = client.get("/text")
    assert resp.status == 200
    assert resp.text() == "plain text"


def test_not_found(client):
    resp = client.get("/nonexistent")
    assert resp.status == 404


def test_method_not_allowed(client):
    resp = client.post("/")
    assert resp.status == 405


def test_path_params(client):
    resp = client.get("/users/42")
    assert resp.status == 200
    assert resp.json() == {"id": "42"}


def test_multiple_path_params(client):
    resp = client.get("/params/hello/world")
    assert resp.status == 200
    assert resp.json() == {"a": "hello", "b": "world"}


def test_204_no_content(client):
    resp = client.get("/status/204")
    assert resp.status == 204


def test_keepalive_sequential(client):
    s = socket.create_connection(("127.0.0.1", client.port), timeout=5)
    try:
        req = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        s.sendall(req)
        resp1 = _read_one_response(s)
        assert b"200 OK" in resp1

        s.sendall(req)
        resp2 = _read_one_response(s)
        assert b"200 OK" in resp2
    finally:
        s.close()


def test_connection_close(client):
    s = socket.create_connection(("127.0.0.1", client.port), timeout=5)
    try:
        req = b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        s.sendall(req)
        resp = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
        assert b"200 OK" in resp
        assert b"Connection: close" in resp
    finally:
        s.close()


def test_malformed_request(client):
    raw = client.send_raw(b"GARBAGE\r\n\r\n")
    resp = raw.decode(errors="replace")
    assert "400" in resp or len(raw) == 0


def test_null_byte_in_path(client):
    resp = client.get("/users/42\x00admin")
    assert resp.status in (400, 404)


def test_percent_encoded_path(client):
    resp = client.get("/users/%34%32")
    assert resp.status == 200
    assert resp.json() == {"id": "42"}


def test_dot_traversal_normalized(client):
    resp = client.get("/users/../users/42")
    assert resp.status == 200
    assert resp.json() == {"id": "42"}


def test_double_slash_collapsed(client):
    resp = client.get("//users//42")
    assert resp.status == 200
    assert resp.json() == {"id": "42"}


def test_post_with_body(client):
    resp = client.post("/echo", body=b"hello world")
    assert resp.status in (200, 204)


def test_post_with_json(client):
    resp = client.post("/echo", json={"key": "value"})
    assert resp.status in (200, 204)


def test_http_10_close(client):
    raw = client.send_raw(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
    assert b"HTTP/1.1" in raw or b"HTTP/1.0" in raw


def test_missing_host_header(client):
    raw = client.send_raw(b"GET / HTTP/1.1\r\n\r\n")
    assert len(raw) > 0


def test_large_header(client):
    big_val = b"X" * 8000
    raw = client.send_raw(
        b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: " + big_val + b"\r\n\r\n"
    )
    assert len(raw) > 0


def test_many_headers(client):
    hdrs = b"".join(f"X-H{i}: val{i}\r\n".encode() for i in range(60))
    raw = client.send_raw(
        b"GET / HTTP/1.1\r\nHost: localhost\r\n" + hdrs + b"\r\n"
    )
    assert len(raw) > 0


def _read_one_response(s):
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            return buf
        buf += chunk
        if b"\r\n\r\n" in buf:
            head, _, body_start = buf.partition(b"\r\n\r\n")
            for line in head.decode().split("\r\n"):
                if line.lower().startswith("content-length:"):
                    cl = int(line.split(":")[1].strip())
                    while len(body_start) < cl:
                        body_start += s.recv(4096)
                    return head.encode() + b"\r\n\r\n" + body_start[:cl] if isinstance(head, str) else buf
            return buf
