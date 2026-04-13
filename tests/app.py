import necro

app = necro.App()


@app.get("/")
async def hello():
    return {"message": "hello"}


@app.get("/text")
async def text():
    return "plain text"


@app.post("/echo")
async def echo(request):
    return request.body


@app.get("/status/204")
async def no_content():
    return None


@app.get("/headers")
async def show_headers(request):
    return dict(request.headers)


@app.get("/users/{id}")
async def get_user(id=None):
    return {"id": id}


@app.get("/params/{a}/{b}")
async def get_params(a=None, b=None):
    return {"a": a, "b": b}
