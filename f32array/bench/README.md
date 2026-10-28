# F32Array benchmark

This times the array ops that a model or feature pipeline runs, on 2^22 `float32` values (16 MiB), in Bend, C, Rust, JavaScript, and NumPy.

## Run

```sh
python3 run.py      # 3 runs, median
python3 run.py 5    # 5 runs
```

You need `bend`, `cc`, `rustc`, `bun`, `node`, `python3`, and NumPy. Binaries go to `out/`, which git ignores. It exits non-zero if a build fails, or if two programs disagree on a checksum.

## The work

`a[i] = (i + 3) & 3` and `b[i] = (5i + 3) & 3`, for N = 2^22. Every partial sum is an integer below 2^24, so each sum is exact in any order and every program prints the same checksums. Each program builds `a`, `b`, and the little-endian bytes of `a` before the first timer, then runs these ops in order:

| op | work | checksum |
|---|---|---|
| `from_bytes` | decode the 16 MiB of little-endian bytes into a new array `a` | `a[N-1] + a[12345]` |
| `sum` | add up `a` | the sum |
| `max` | the largest element of `a` | the max |
| `dot` | the sum of `a[i] * b[i]` | the dot product |
| `map` | `a[i] *= 2`, in place | `a[N-1] + a[12345]` |
| `add` | `a[i] += b[i]`, in place | `a[N-1] + a[12345]` |
| `to_bytes` | encode `a` as little-endian bytes in a new buffer | byte count + last byte |

Each language uses its obvious loop or standard call. C uses `memcpy` and plain loops (so it assumes a little-endian host). Rust uses `Vec<f32>` with `chunks_exact`, `from_le_bytes`, and iterator `sum`, `fold`, and `zip`. Bun and Node use `Float32Array` and `for` loops. Python's standard library has no vector math, so the Python column is NumPy: `frombuffer`, `sum`, `max`, `dot`, `*=`, `+=`, and `tobytes`.

## Results

M4 Pro, macOS, 2026-10-27. Bend 2.0.38, Apple clang 17.0.0 (`-O2`), rustc 1.91.0 (`opt-level=3`), Bun 1.3.14, Node 24.0.1, Python 3.14.6 with NumPy 2.4.2. Median of five runs. Times are in ms; `Nx` is the multiple of the fastest program for that op.

| op | C | Rust | Bun | Node | NumPy | Bend |
|---|---:|---:|---:|---:|---:|---:|
| from_bytes | 1.35 (3.0x) | 2.24 (5.0x) | 1.79 (4.0x) | 1.46 (3.2x) | 0.45 (1.0x) | 3.49 (7.8x) |
| sum | 2.39 (4.6x) | 2.50 (4.9x) | 7.42 (14.4x) | 10.77 (20.9x) | 0.51 (1.0x) | 2.49 (4.8x) |
| max | 2.13 (10.8x) | 0.26 (1.3x) | 4.35 (22.0x) | 5.38 (27.3x) | 0.20 (1.0x) | 12.87 (65.3x) |
| dot | 2.61 (8.3x) | 2.75 (8.8x) | 24.54 (78.4x) | 25.64 (81.9x) | 0.31 (1.0x) | 2.99 (9.6x) |
| map | 0.27 (1.0x) | 0.30 (1.1x) | 20.70 (78.1x) | 3.22 (12.2x) | 0.27 (1.0x) | 1.37 (5.2x) |
| add | 0.36 (1.0x) | 0.36 (1.0x) | 6.38 (17.9x) | 8.14 (22.8x) | 0.37 (1.1x) | 1.62 (4.6x) |
| to_bytes | 1.28 (4.5x) | 1.26 (4.5x) | 0.28 (1.0x) | 0.39 (1.4x) | 2.52 (8.9x) | 2.22 (7.9x) |
| geomean vs fastest | 3.4x | 2.8x | 14.6x | 12.9x | 1.4x | 8.9x |

Every program printed checksums `2`, `6291456`, `3`, `14680064`, `4`, `6`, and `16777280`.

## Reading it

- `sum` and `dot` in Bend match C and Rust. All three add one element at a time in order, because IEEE rules stop the compiler from reordering the adds into SIMD lanes. NumPy adds pairwise with SIMD, and its `dot` calls BLAS, so it is 5 to 10 times faster.
- `map` and `add` are 4 to 5 times slower than C. Each element costs one `Array.get` and one `Array.set` on Bend's tree array.
- `max` is the weak spot: 12.9 ms against 2.1 ms in C. A version that matched on `F32.is_lt` instead of calling Base `F32.max` took the same time, so the cost is in the compare, not in `Bool.pick`. This is not confirmed.
- `from_bytes` and `to_bytes` are one `Array.map` that reinterprets each word. C and JS copy the memory.
- Every Bend op is one sequential loop. A fork-join split over the array's tree would use every core and give a pairwise sum. It has not been tried.

## Caveats

- Bend times itself with `Time.mono`, a nanosecond clock. It prints each checksum before the second clock read, so the work is forced inside the timer.
- These are micro-benchmarks on one machine, at one size.
