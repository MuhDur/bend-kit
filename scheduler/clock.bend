# Monotonic clock adapter for consumers, outside the pure scheduler core.
import Base
import bend-kit-time@0.1.2.1/time.bend as Time

# Microseconds avoid exceeding native Nat's 2^48-1 ceiling on normal uptimes.
# Crossing that ceiling reports Bend's explicit Nat-overflow error, never wraps.
def micros(r: U32 & U32 & U32) -> Nat:
  (hi, lo, ns) = r
  ((U32.to_nat(hi) * (65536n * 65536n : Nat) + U32.to_nat(lo)) *
    1000000n + U32.to_nat((ns / 1000 : U32)) : Nat)

def now_us() -> IO(Nat):
  do IO<Nat>:
    raw : U32 & U32 & U32 <- Time.mono.raw()
    return micros(raw)

def now() -> IO(Nat):
  do IO<Nat>:
    us : Nat <- now_us()
    return Nat.div(us, 1000n)
