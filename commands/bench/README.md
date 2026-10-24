# commands benchmark

This times `commands.handle`, one command in one SQLite transaction, in Bend and in C, Rust, JavaScript (Bun), and Python. No language has a standard idempotency library, so each variant runs the obvious loop over the same schema and SQL that `commands.open` creates. The payload, state, result, and effect are BLOBs in every variant:

- `BEGIN IMMEDIATE`, then `SELECT payload, kind, result, at FROM commands_seen WHERE id = ?`.
- **Duplicate:** compare the payload bytes, then `COMMIT`.
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
- The domain state is a decimal total, starting at `0`. A new command adds its amount. The result is the new total, and the outbox row is `total=<new total>`. Each is stored as the bytes of its ASCII text.
- The `fresh` checksum is the final total, read after the timer stops. The `replay` checksum is `h = h*31 + result` in wrapping u32 over every duplicate's recorded result.

With N = 10,000 the checksums are **5023800** and **1224217884**. With N = 2,000 they are **1018672** and **1045709524**. With N = 500 they are **259210** and **2276155089**.

## Results

Checksums agree across all five variants. Apple M-series (arm64), macOS 26.6.2, 2026-10-24. Median of three runs. Times are in ms.

In-memory database, N = 10,000:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 37.3 | 268,039 | 1.0x | 6.5 | 1,527,884 | 1.0x |
| Rust | 3.51.0 | 38.6 | 259,188 | 1.0x | 6.4 | 1,560,062 | 1.0x |
| Bun | 3.51.0 | 55.4 | 180,518 | 1.5x | 13.7 | 729,182 | 2.1x |
| Python | 3.54.0 | 75.6 | 132,315 | 2.0x | 23.1 | 432,563 | 3.6x |
| Bend | 3.51.0 | 94.7 | 105,638 | 2.5x | 35.3 | 283,466 | 5.5x |

File database, N = 2,000. Each new command's `COMMIT` waits for the disk, so `fresh` measures the disk more than the language:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 895.2 | 2,234 | 1.1x | 13.9 | 144,144 | 1.2x |
| Rust | 3.51.0 | 875.1 | 2,285 | 1.1x | 11.9 | 168,492 | 1.0x |
| Bun | 3.51.0 | 829.3 | 2,412 | 1.1x | 15.3 | 130,370 | 1.3x |
| Python | 3.54.0 | 786.7 | 2,542 | 1.0x | 14.1 | 141,373 | 1.2x |
| Bend | 3.51.0 | 818.6 | 2,443 | 1.0x | 19.4 | 103,143 | 1.6x |

Versions: Bend 2.0.38, Apple clang 17.0.0, rustc 1.91.0, Bun 1.3.14, Python 3.14.6.

A duplicate costs Bend one indexed lookup, a payload compare, and a `COMMIT`, as in the other variants: `handle` reads the state row only when the id has no record. Skipping that read took the in-memory replay from 43.0 ms to 35.3 ms. For a new command, `step` copies the payload and the result, because each goes both to its consumer and to the record. The bench's `decide` converts each decimal between `Bytes` and `String`, because `bend-kit-bytes` has no decimal parser.
