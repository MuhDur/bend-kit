# Runner benchmark

This times replay at `open`: scanning the journal's frames, checking each CRC-32, decoding each record, and applying it to the queue. Replay is the runner's CPU hot path. A live transition is one fsync, which the disk dominates.

It replays the bench log twice: as written, and as `compact` leaves it, one frame that holds the snapshot of the final state.

## Run

```sh
python3 run.py        # 3 runs per variant, median, 2^16 jobs
python3 run.py 5 14   # 5 runs, 2^14 jobs
```

You need `bend` (2.0.37), `cargo`, and `python3`. Cargo fetches `crc32fast` 1.5.0. Binaries go to `out/`, which git ignores. It exits non-zero if a build fails, a program prints no result, or two programs or rows disagree on the checksum or the counts.

## Input

J = 2^16 jobs, so the log holds 3 × 2^16 = 196,608 records:

1. For each job i: `Enqueue{deadline = (i * 37) mod 1024, payload = i as u32le}`.
2. J rounds of `Select{1024}`, then, for the selected ticket, `Complete{id}` in the first J/2 rounds and `Requeue{id, 2048 + k}` in round k after that.

The records and frames are as `runner.bend` and `journal` write them. Each program builds the log before the timer starts. The generators find the selected ids by sorting on (deadline, id); Bend runs the runner's own `step`. Bend also builds the compacted journal before the timer: `J.frame(R.encode.snap(state))`.

The timed region scans every frame, checks `~len` and the CRC-32, decodes the record, applies it, and then sums `id * 31 + deadline` over the pending tickets, mod 2^32.

| language | replay |
|---|---|
| Bend | `J.replay.bytes` folding `R.replay.step`: the code that `open` runs |
| Rust | `crc32fast` 1.5.0, `std::collections::BinaryHeap`, `HashMap`, `HashSet` |
| Python | `zlib.crc32`, `struct.unpack_from`, `heapq`, `dict`, `set` |

C and JavaScript are left out: neither standard library has a priority queue, and the replay needs a dynamic one. Only Bend has the `compacted` row: the baselines have no snapshot format, and writing one would be a second runner.

## Results

Apple M4 Pro, macOS 26.6.2 arm64, 2026-10-18. Three runs (`python3 run.py`), median, in ms. `Nx` is the multiple of the fastest variant.

Versions: Bend 2.0.37, rustc 1.91.0, crc32fast 1.5.0, Python 3.14.6.

| op | Rust | Python | Bend |
|---|---:|---:|---:|
| replay | 13.4 (1.0x) | 279.1 (20.8x) | 567.7 (42.2x) |
| compacted | - | - | 134.7 (10.0x) |

Every program and row prints checksum `607518720` and `32768/65536` (pending tickets / next id).

## Reading it

Compaction cuts open's replay by 4.2x here. The log holds 196,608 records, and the compacted journal holds one: the 32,768 pending tickets and their tries. Replay time then follows the live state, not the history. Half of the jobs here are still pending; a runner whose jobs finish gains more.

Replay is O(n log n) in Bend: the queue is a heap, and the tries are an ordered map. Native Bend took 19 ms at 2^12 jobs, 83 ms at 2^14, and 431 ms at 2^16 on Bend 2.0.36. A snapshot rebuilds the same trees without the heap and map work, so its decode is linear in its size.

`journal`'s bench shows that its frame scan alone takes about 300 ms for 2^20 records, because `Hash.crc32` rebuilds its table per record. Here the scan is a part of the total, and the heap and map work is the rest. This bench does not split them.

## Caveats

- Bend times itself with `Time.mono`. It reads the size from argv, so the replay cannot run before the clock starts. Building the log is outside the timer.
- One machine, one size, one thread.
- The Rust and Python loops are the obvious replay over a standard-library heap. They keep payloads and tries in hash maps, as the runner keeps them in its state. They are not a second runner: they have no retry, breaker, or pool.
