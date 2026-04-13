"""Bare ASGI app - no framework, just the raw protocol. Ceiling for ASGI servers."""

BODY = b'{"message":"Hello, World!"}'


async def app(scope, receive, send):
    assert scope["type"] == "http"
    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"application/json")],
        }
    )
    await send({"type": "http.response.body", "body": BODY})
