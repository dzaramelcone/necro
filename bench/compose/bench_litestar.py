from litestar import Litestar, get


@get("/", sync_to_thread=False)
def hello() -> dict:
    return {"message": "Hello, World!"}


app = Litestar(route_handlers=[hello])
