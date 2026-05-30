# necro

An unreasonably fast Python web framework. 🧟‍♀️ 💨

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
Note the memory stability. (I'll address the tail latency once the feature set matures.)

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

As usual benchmarks tend to be very distinct from real deployment performance scenarios but my interest in developing Necro is in delivering a performance experience that is in a separate tier from standard Python web frameworks and even from other languages' performance-oriented frameworks.

There are so many axes and features to test for web server performance and this is a tiny slice of those dimensions, so I'm going to get a benchmark together that gives everyone (including me) a better idea and understanding of real performance use cases at a glance.

## Simple
A familiar developer experience:

```python
# app.py
import necro
app = necro.App()

@app.get("/")
async def raise_dead():
    return {"data": "the dead rise"}
```

Though, this might be less familiar:

```bash
necro host app --cert my_cert.crt --key my_cert.key
```

Just one process for deployment hosting. Bye Gunicorn! Thanks for the good times.

### Postgres

Necro has Postgres support built in using its own Postgres driver in Zig.

I found it faster than libpq so far.

```python
import necro
app = necro.App()

@app.get("/summon/{id}")
async def summon_one(db, id):
    return await db.fetch_one(
        "SELECT id, name, power FROM minions WHERE id = $1",
        id
    )

@app.post("/raise")
async def raise_dead(db, body):
    return await db.execute(
        "INSERT INTO minions (name, power) VALUES ($1, $2)",
        body.name,
        body.power
    )
```

These get a million+ QPS. There are also some neat new features in the Postgres protocol and the Linux kernel for speeding this up even further that I want to take advantage of.

### Redict

Same for Redict. Wow, the Redict protocol is extremely easy to implement.

```python
import necro

app = necro.App()

@app.post("/bind")
async def bind(redis, body):
    await redis.set(body.name, body.soul)
    await redis.expire(body.name, 3600)
    return {"bound": body.name, "ttl": 3600}
```

### Type-safe SQL

The framework's recommended approach to using the db.

Postgres queries return tuples. You can easily map these to structured data.

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

Now `db` will have your queries:

```python
# Note the attribute accessor matches your filename.
await db.spells.summon_zombie(id=id)
await db.spells.raise_horde()
```

Serve type-safe results from your routes:

```python
import necro

app = necro.App()

# Note that you can also inject that directly:
@app.post("/summon")
async def raise_horde(spells) -> list[Zombie]:
    return await spells.raise_horde()
```

### HTMX
Under development, check back soon.

### OpenAPI
Under development, check back soon.

### Validations
Currently, I am using speculative SIMD JSON, which can serialize at about 20GB/s on my mbp.

More soon on this topic.

### Client
Under development, check back soon.

### Websockets
Under development, check back soon.

## One dependency
The entire lib is 2MB.

```bash
pip install necro
```

1.5MB of that is BoringSSL, lol.

No supply chain? No supply chain attacks!

## How?

Relative to other Python frameworks, Necro's edge is subinterpreters. It obviates the need for a lot of workarounds Python developers have had to do to solve GIL lock contention. There is no contention in Necro.  

But going a step further, Necro owns the whole stack; the runtime, the drivers, the request/response pipeline, the parsing, the routing, the serializer/deserializer, etc. The ability to deeply integrate all of these systems opens up many new performance possibilities.
