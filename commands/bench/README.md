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

Checksums agree across all five variants. Apple M-series (arm64), macOS 26.6.2, 2026-10-18. Median of three runs. Times are in ms.

In-memory database, N = 10,000:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 40.5 | 246,853 | 1.0x | 6.5 | 1,548,467 | 1.0x |
| Rust | 3.51.0 | 39.2 | 255,408 | 1.0x | 6.5 | 1,532,332 | 1.0x |
| Bun | 3.51.0 | 55.6 | 179,743 | 1.4x | 13.6 | 736,865 | 2.1x |
| Python | 3.54.0 | 73.2 | 136,562 | 1.9x | 22.5 | 443,597 | 3.5x |
| Bend | 3.51.0 | 93.5 | 106,995 | 2.4x | 43.0 | 232,474 | 6.7x |

File database, N = 2,000. Each new command's `COMMIT` waits for the disk, so `fresh` measures the disk more than the language:

| variant | SQLite | fresh ms | commands/s | vs fastest | replay ms | duplicates/s | vs fastest |
|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 3.51.0 | 698.0 | 2,866 | 1.0x | 13.3 | 150,410 | 1.1x |
| Rust | 3.51.0 | 942.6 | 2,122 | 1.4x | 11.9 | 167,616 | 1.0x |
| Bun | 3.51.0 | 792.6 | 2,523 | 1.1x | 15.3 | 130,412 | 1.3x |
| Python | 3.54.0 | 719.8 | 2,779 | 1.0x | 13.8 | 144,467 | 1.2x |
| Bend | 3.51.0 | 721.2 | 2,773 | 1.0x | 19.1 | 104,569 | 1.6x |

Versions: Bend 2.0.37, Apple clang 17.0.0, rustc 1.91.0, Bun 1.3.14, Python 3.14.6.

Bend reads the state row on a duplicate too, because `step` takes the state before it knows whether the id has a record. The other variants skip that read. For a new command, `step` copies the payload and the result, because each goes both to its consumer and to the record. The bench's `decide` converts each decimal between `Bytes` and `String`, because `bend-kit-bytes` has no decimal parser.
