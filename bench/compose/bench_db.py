import necro

app = necro.App()

@app.get("/")
async def db_query():
    return await app.db.fetch_one("SELECT 1 as id, 'hello' as name", )
