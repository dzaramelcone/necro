"""necro application class with FastAPI-style decorators."""

from necro import core


class App:
    def __init__(self):
        self._routes = []
        self.redis = Redis()
        self.db = Db()

    def get(self, path):
        return self._route("GET", path)

    def post(self, path):
        return self._route("POST", path)

    def put(self, path):
        return self._route("PUT", path)

    def delete(self, path):
        return self._route("DELETE", path)

    def patch(self, path):
        return self._route("PATCH", path)

    def _route(self, method, path):
        def decorator(func):
            core.add_route(method, path, func)
            self._routes.append((method, path, func))
            return func
        return decorator


class Redis:
    def get(self, key: str):
        return core.redis_get(key)

    def set(self, key: str, value: str):
        return core.redis_set(key, value)

    def setex(self, key: str, seconds: int, value: str):
        return core.redis_setex(key, str(seconds), value)

    def delete(self, *keys: str):
        return core.redis_del(*keys)

    def incr(self, key: str):
        return core.redis_incr(key)

    def expire(self, key: str, seconds: int):
        return core.redis_expire(key, str(seconds))

    def ttl(self, key: str):
        return core.redis_ttl(key)

    def exists(self, *keys: str):
        return core.redis_exists(*keys)

    def ping(self):
        return core.redis_ping()


class Db:
    def fetch_one(self, sql: str, *params):
        return core.pg_fetch_one(sql, params)

    def fetch_all(self, sql: str, *params):
        return core.pg_fetch_all(sql, params)

    def execute(self, sql: str, *params):
        return core.pg_execute(sql, params)
