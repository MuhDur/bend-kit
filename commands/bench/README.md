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
| C | 3.51.0 | 37.4 | 267,501 | 1.0x | 6.6 | 1,519,064 | 1.0x |
| Rust | 3.51.0 | 38.4 | 260,193 | 1.0x | 6.4 | 1,554,485 | 1.0x |
| Bun | 3.51.0 | 56.5 | 176,882 | 1.5x | 13.6 | 734,592 | 2.1x |
| Python | 3.54.0 | 75.5 | 132,528 | 2.0x | 22.8 | 439,116 | 3.5x |
| Bend | 3.51.0 | 89.1 | 112,293 | 2.4x | 34.1 | 292,915 | 5.3x |

File database, N = 2,000. Each new command's `COMMIT` waits for the disk, so `fresh` measures the disk more than the language:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 799.4 | 2,502 | 1.1x | 15.0 | 133,485 | 1.1x |
| Rust | 3.51.0 | 717.2 | 2,788 | 1.0x | 13.1 | 152,777 | 1.0x |
| Bun | 3.51.0 | 760.4 | 2,630 | 1.1x | 16.5 | 121,411 | 1.3x |
| Python | 3.54.0 | 776.4 | 2,576 | 1.1x | 13.8 | 144,938 | 1.1x |
| Bend | 3.51.0 | 745.5 | 2,683 | 1.0x | 18.7 | 107,037 | 1.4x |

Versions: Bend 2.0.38, Apple clang 17.0.0, rustc 1.91.0, Bun 1.3.14, Python 3.14.6.

A duplicate costs Bend one indexed lookup, a payload compare, and a `COMMIT`, as in the other variants: `handle` reads the state row only when the id has no record. Skipping that read took the in-memory replay from 43.0 ms to 35.3 ms. For a new command, `step` copies the payload and the result, because each goes both to its consumer and to the record. The bench's `decide` reads and writes each decimal with `Bytes.u32.read` and `Bytes.u32.show`. Dropping the trip through `String` took the in-memory fresh pass from 94.7 ms to 89.1 ms.
