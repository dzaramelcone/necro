import necro

app = necro.App()

@app.get("/")
def hello():
    return b"Hello, World!"
