# necro

The fastest Python web framework.

The fastest HTTP/1.1 web server, period!  🧟‍♀️ 💨

## Speed

Under maximum load from 4K users:

```
  ⎿  Summary:
       Success rate:    100.00%
       Total:   10,005.1308 ms
       Slowest: 90.9730 ms
       Fastest: 0.0117 ms
       Average: 0.6949 ms
       Requests/sec:    1,453,431.8677

       Total data:      416.02 MiB
       Size/request:    30 B
       Size/sec:        41.58 MiB

     Response time distribution:
       10.00% in 0.1609 ms
       25.00% in 0.1992 ms
       50.00% in 0.2903 ms
       75.00% in 0.7278 ms
       90.00% in 1.6830 ms
       95.00% in 2.8445 ms
       99.00% in 4.7198 ms
       99.90% in 7.2662 ms
       99.99% in 9.7244 ms


Memory:
    startup:       63 MB
    after warmup:  93 MB 
    under load:   105 MB
    peak RSS:     105 MB
```

Benchmarked on consumer hardware. No pipelining!

Comparisons with simple json payloads:
```
server                    req/s       avg latency
necro                     1,514,316   240 µs
nginx                     1,310,342   261 µs
fasthttp (Go)             1,142,127   351 µs
uvicorn, bare ASGI        556,123     441 µs
granian, bare ASGI        549,132     445 µs
Go net/http stdlib        502,746     684 µs
uvicorn + litestar        260,007     0.97 ms
uvicorn + starlette       50,976      5.01 ms
uvicorn + fastapi         29,852      8.56 ms
```

## Simple
A familiar developer experience:

```python
import necro
app = necro.App()

@app.get("/")
async def raise():
    return {"message": "the dead rise"}

app.run()
```

```bash
necro run app:app
```

### Postgres

Built-in first-class Postgres support!

```python
import necro
app = necro.App()

@app.get("/summon/{id}")
async def summon_one(db, id):
    return await db.fetch_one("SELECT id, name, power FROM minions WHERE id = $1", id)

@app.post("/raise")
async def raise_dead(db, body):
    return await db.execute(
        "INSERT INTO minions (name, power) VALUES ($1, $2)",
        body.name,
        body.power
    )

app.run()
```

### Redis

Built-in first-class Redis support!

```python
import necro

app = necro.App()

@app.post("/bind")
async def bind(redis, body):
    await redis.set(body.name, body.soul)
    await redis.expire(body.name, 3600)
    return {"bound": body.name, "ttl": 3600}

app.run()
```

### Type-safe SQL

The framework's recommended approach to using the db.

Highly optimized!

Define your schema:

```sql
-- undead.sql

CREATE TABLE zombies (
    id SERIAL PRIMARY KEY,
    decay_rate REAL,
    graveyard TEXT,
);
```

Define your queries:

```sql
-- spells.sql

-- name: SummonZombie :one
SELECT * FROM zombies WHERE id = {id};

-- name: RaiseHorde :many
SELECT * FROM zombies ORDER BY decay_rate ASC;
```

!!! info
Did you know Claude's best language is SQL?

Generate methods and models, complete with type hints and validations:

```bash
necro scribe
```

generates:

```python
# undead.py
class Zombie(NecroModel):
    id: int
    decay_rate: float
    graveyard: str
```

Now the `db` will have your queries:

```python
await db.spells.summon_zombie(id=id)
await db.spells.raise_horde()
```

Serve type-safe results from your routes:

```python
import necro

app = necro.App()

@app.post("/summon")
async def raise_horde(spells) -> list[Zombie]:
    return await spells.raise_horde()

app.run()
```
### OpenAPI

### Validations

### Client

### Websockets

## One dependency

```bash
pip install necro
```
