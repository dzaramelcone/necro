# necro

The fastest Python web framework.

The fastest HTTP/1.1 web server, period!  🧟‍♀️ 💨

## Speed

Benchmarked on consumer hardware. With 1024 concurrent connections:

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

     Response time histogram:
        0.012 ms [2]        |
        9.108 ms [14538403] |■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
       18.204 ms [2197]     |
       27.300 ms [68]       |
       36.396 ms [0]        |
       45.492 ms [49]       |
       54.589 ms [65]       |
       63.685 ms [45]       |
       72.781 ms [7]        |
       81.877 ms [2]        |
       90.973 ms [23]       |

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
    startup:     63 MB
    after warmup: 93 MB  (pools allocated, sub-interpreters created)
    under load: 105 MB   (stable, no growth)
    peak RSS:   105 MB
```

## Convenience
A familiar developer experience:

```
import necro
app = necro.App()

@app.get("/")
async def raise():
    return {"message": "the dead rise"}

app.run()
```

## One dependency
```
pip install necro
```

### Postgres

Built-in Postgres support.

```
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

Built-in Redis support.

```
import necro

app = necro.App()

@app.post("/bind/{name}")
async def bind(redis, body, name):
    await redis.set(name, body.soul)
    await redis.expire(name, 3600)
    return {"bound": name, "ttl": 3600}

app.run()
```

### Type-safe SQL

The recommended approach to using the db. Highly optimized.

Define your schema.

```sql
CREATE TABLE IF NOT EXISTS zombies (
    id SERIAL PRIMARY KEY,
    decay_rate REAL NOT NULL DEFAULT 0.0,
    graveyard TEXT NOT NULL DEFAULT 'unknown',
);
```

Define your queries.

```sql
-- name: SummonZombie :one
SELECT * FROM zombies WHERE id = {id};

-- name: RaiseHorde :many
SELECT * FROM zombies ORDER BY decay_rate ASC;
```

Generate methods and models, complete with type hints and validations.
```bash
necro scribe
```

Serve type-safe results from your routes.

```python
import necro

app = necro.App()

@app.post("/summon")
async def summon(db) -> list[Zombie]:
    return await db.raise_horde()

app.run()
```

### Client

### Websockets

### Validations

