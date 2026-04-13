import necro

app = necro.App()


@app.get("/")
async def index():
    return await app.redis.ping()
