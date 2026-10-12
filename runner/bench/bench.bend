# Runner replay benchmark: the Bend side (see README.md).
import Base
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
import bend-kit-journal@0.2.0.0/journal.bend as J
import bend-kit-scheduler@0.2.0.0/queue.bend as Q
import bend-kit-collections@0.1.2.0/heap.bend as H
import bend-kit-time@0.2.0.0/time.bend as Time
import ../runner.bend as R

def penc(x: U32) -> Bytes.Bytes:
  Bytes.set.u32le(Bytes.new(4), 0, x)

def pdec.of(r: Bytes.Bytes & Maybe<&2, U32>) -> Maybe<&2, U32>:
  (b, m) = r
  m

def pdec(b: Bytes.Bytes) -> Maybe<&2, U32>:
  pdec.of(Bytes.get.u32le(b, 0))

# The log and the live state it leads to: frames are appended as the live runner would.
type Gen is Type:
  Gen{log: Bytes.Bytes, state: R.State<U32>}

def put(g: Gen, +op: R.Op<U32>) -> Gen:
  Gen{b, s} = g
  Gen{Bytes.append(b, J.frame(R.encode(~U32, ~penc, op))), R.step(~U32, s, op)}

# Enqueue i with deadline (i * 37) % 1024 and payload i.
def enqueues(k: Nat, g: Gen, +i: U32) -> Gen:
  match k:
    case 0n:
      g
    case 1n+p:
      enqueues(p, put(g, R.Enqueue{U32.to_nat(((i * 37 : U32) % 1024 : U32)), i}), (i + 1 : U32))

def head(xs: List<&2, Q.Ticket<U32>>) -> Nat:
  match xs:
    case Con{t, rest}:
      Q.id(U32, t)
    case Nil{}:
      0n

def after(+k: Nat, +half: Nat, +id: Nat) -> R.Op<U32>:
  Bool.pick(R.Op<U32>, Nat.is_lt(k, half), R.Complete{id}, R.Requeue{id, Nat.add(2048n, k)})

def finish(g: Gen, +k: Nat, +half: Nat) -> Gen:
  Gen{b, +s} = g
  put(Gen{b, s}, after(k, half, head(Q.running(U32, R.queue(U32, s)))))

# Select at 1024 takes the next ticket; the first half complete, the rest requeue at 2048 + k.
def rounds(k: Nat, g: Gen, +j: Nat, +half: Nat) -> Gen:
  match k:
    case 0n:
      g
    case 1n+p:
      rounds(p, finish(put(g, R.Select{1024n}), j, half), 1n+j, half)

def log(g: Gen) -> Bytes.Bytes:
  Gen{b, s} = g
  b

def build(+n: Nat) -> Bytes.Bytes:
  log(rounds(n, enqueues(n, Gen{Bytes.new(0), R.new(U32)}, 0), 0n, Nat.div(n, 2n)))

# Sum of id * 31 + deadline over the pending tickets, and their count.
def sum(h: H.Heap<Q.Ticket<U32>>, +acc: Nat) -> Nat:
  match h:
    case H.HLeaf{}:
      acc
    case H.HNode{n, Q.Ticket{+i, +d, x}, l, r}:
      sum(l, sum(r, Nat.add(acc, Nat.add(Nat.mul(i, 31n), d))))

def shown(m: Maybe<&2, R.State<U32>>, t0: Time.Duration) -> IO(Unit):
  match m:
    case Some{R.State{Q.State{next, +h, run}, ts}}:
      do IO<Unit>:
        IO.print("chk\treplay\t" ++ Nat.show(Nat.mod(sum(h, 0n), Nat.mul(65536n, 65536n))))
        IO.print("n\treplay\t" ++ Nat.show(H.Heap.size(Q.Ticket<U32>, h)) ++ "/" ++ Nat.show(next))
        t1 : Time.Duration <- Time.mono()
        IO.print("ms\treplay\t" ++ Time.Duration.show_ms(Time.Duration.sub(t1, t0)))
    case None{}:
      IO.die(Unit, 1, "replay met a record that is not an op")

def at(t0: Time.Duration, r: J.Replay<Maybe<&2, R.State<U32>>, J.Cur>) -> IO(Unit):
  J.Replay{acc, t, rest} = r
  shown(acc, t0)

def lg(args: List<&1, String>) -> Nat:
  match args:
    case program <> k <> Nil{}:
      U32.to_nat(Maybe.default(&2, U32, U32.read(k), 15))
    case _:
      15n

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<&1, String> <- IO.args()
    b : Bytes.Bytes = build(Nat.pow(2n, lg(args)))
    t0 : Time.Duration <- Time.mono()
    at(t0, J.replay.bytes(~Maybe<&2, R.State<U32>>, ~(a => p => R.replay.step(~U32, ~pdec, a, p)), 64, b, Some{R.new(U32)}))
