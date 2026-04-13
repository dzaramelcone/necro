import necro.core as core

core.add_route("GET", "/", lambda: {"message": "hello from necro"})
core.add_route("GET", "/health", lambda: None)

if __name__ == "__main__":
    print("starting necro on :8080")
    core.run("0.0.0.0", 8080, 1, "app:core", 128)
