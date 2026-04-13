from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def hello() -> dict:
    return {"message": "Hello, World!"}
