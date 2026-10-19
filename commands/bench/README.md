# commands benchmark

This times `commands.handle`, one command in one SQLite transaction, in Bend and in C, Rust, JavaScript (Bun), and Python. No language has a standard idempotency library, so each variant runs the obvious loop over the same schema and SQL that `commands.open` creates:

- `BEGIN IMMEDIATE`, then `SELECT payload, kind, result, at FROM commands_seen WHERE id = ?`.
- **Duplicate:** compare the payload, then `COMMIT`.
- **New command:** read the state row, add the amount, `UPDATE` the state, `INSERT` the record, `INSERT` one outbox row, then `COMMIT`.

Two passes are timed:

- **`fresh`**: **N** new commands.
- **`replay`**: the same **N** commands again. Each must be a duplicate.

## Run

Run these commands from `commands/bench/`.

```sh
python3 run.py               # 3 runs per variant, median, N = 10,000, in-memory database
python3 run.py 3 2000 file   # a file database in out/: every COMMIT syncs to disk
python3 run.py 1 500         # check RSS and checksums first after a change
```

You need `bend`, `cc`, `rustc`, `bun`, `python3`, and a system `libsqlite3`. `run.py` writes the binaries and the database to `out/`, which git ignores. It removes the database before each run. It exits non-zero if a build or run fails, or if two variants print different checksums.

| variant | SQLite API |
|---|---|
| C | libsqlite3 C API (`-lsqlite3`) |
| Rust | libsqlite3 C API through `extern "C"`, no crates |
| Bun | `bun:sqlite` |
| Python | `sqlite3` (standard library) |
| Bend | `commands.handle` over `bend-kit-sqlite` |

Rust's standard library has no SQLite, so `bench.rs` links libsqlite3 directly, as `sqlite/bench` does. Node is left out: `node:sqlite` is still experimental.

## Input

- Command **i** (0 ≤ i < N) has id `cmd_i` and payload `(x_i >> 1) mod 1000` in decimal, with `x_0 = 1` and `x_{i+1} = x_i * 1664525 + 1013904223` in wrapping u32.
- The domain state is a decimal total, starting at `0`. A new command adds its amount. The result is the new total, and the outbox row is `total=<new total>`.
- The `fresh` checksum is the final total, read after the timer stops. The `replay` checksum is `h = h*31 + result` in wrapping u32 over every duplicate's recorded result.

With N = 10,000 the checksums are **5023800** and **1224217884**. With N = 2,000 they are **1018672** and **1045709524**. With N = 500 they are **259210** and **2276155089**.

## Results

Checksums agree across all five variants. Apple M-series (arm64), macOS 26.6.2, 2026-10-18. Median of three runs. Times are in ms.

In-memory database, N = 10,000:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 38.3 | 261,274 | 1.0x | 6.7 | 1,485,443 | 1.0x |
| Rust | 3.51.0 | 39.7 | 251,965 | 1.0x | 6.9 | 1,454,969 | 1.0x |
| Bun | 3.51.0 | 59.2 | 169,019 | 1.5x | 12.7 | 788,457 | 1.9x |
| Python | 3.54.0 | 73.1 | 136,790 | 1.9x | 23.7 | 421,674 | 3.5x |
| Bend | 3.51.0 | 93.6 | 106,881 | 2.4x | 42.0 | 238,138 | 6.2x |

File database, N = 2,000. Each new command's `COMMIT` waits for the disk, so `fresh` measures the disk more than the language:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 1,377.0 | 1,452 | 1.0x | 22.9 | 87,527 | 1.3x |
| Rust | 3.51.0 | 1,712.8 | 1,168 | 1.2x | 21.3 | 93,712 | 1.2x |
| Bun | 3.51.0 | 3,367.3 | 594 | 2.4x | 17.6 | 113,785 | 1.0x |
| Python | 3.54.0 | 4,351.3 | 460 | 3.2x | 17.6 | 113,908 | 1.0x |
| Bend | 3.51.0 | 1,560.8 | 1,281 | 1.1x | 28.0 | 71,550 | 1.6x |

Versions: Bend 2.0.37, Apple clang 17.0.0, rustc 1.91.0, Bun 1.3.14, Python 3.14.6.

Bend reads the state row on a duplicate too, because `step` takes the state before it knows whether the id has a record. The other variants skip that read. Bend also builds each id and payload as a `String`, a list of `Char`, and each effect converts it at the boundary.
