from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route


def hello(request):
    return JSONResponse({"message": "Hello, World!"})


app = Starlette(routes=[Route("/", hello)])
