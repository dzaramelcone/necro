import necro

app = necro.App()

@app.get("/")
async def hello():
    return {"message": "hello"}
