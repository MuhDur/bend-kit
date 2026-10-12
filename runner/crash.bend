# check.bend runs this as a child process: it completes job x, then dies inside job y's attempt.
import Base
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
import bend-kit-retry@0.1.0.0/retry.bend as Retry
import ./runner.bend as R

def penc(s: String) -> Bytes.Bytes:
  Bytes.from_string(s)

def pdec(b: Bytes.Bytes) -> Maybe<&2, String>:
  Some{Bytes.to_string(b)}

def note.close(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, x) = r
  File.close(f)

def note(+log: String, +spec: String) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(log, "a"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, spec ++ "\n")
    note.close(r)

def die.if(crash: Bool) -> IO(Retry.Outcome):
  match crash:
    case True{}:
      IO.die(Retry.Outcome, 9, "crash: killed inside an attempt")
    case False{}:
      IO.pure(Retry.Outcome, Retry.Settled{})

def work.go(xs: List<&2, String>) -> IO(Retry.Outcome):
  match xs:
    case Con{log, Con{+spec, Nil{}}}:
      do IO<Retry.Outcome>:
        note(log, spec)
        die.if(String.starts_with(spec, "crash:"))
    case _:
      IO.pure(Retry.Outcome, Retry.Settled{})

def work(s: String) -> IO(Retry.Outcome):
  work.go(String.split(s, '|'))

def target(s: String) -> String:
  "local"

def config() -> R.Config:
  R.Config{Retry.Policy{3n, 1n, 4, None{}}, Retry.Circuit{100n, 60000n, 60000n, 1n}, 5}

def enq.got(y: R.Runner<String> & R.Out(Nat)) -> IO(R.Runner<String>):
  match y:
    case (r, Done{i}):
      IO.pure(R.Runner<String>, r)
    case (r, Fail{(c, m)}):
      IO.die(R.Runner<String>, 1, "crash: enqueue failed: " ++ m)

def enq(r: R.Runner<String>, +d: Nat, +x: String) -> IO(R.Runner<String>):
  do IO<R.Runner<String>>:
    y : R.Runner<String> & R.Out(Nat) <- R.enqueue(~String, ~penc, r, d, x)
    enq.got(y)

def last(xs: List<String>, +d: String) -> String:
  match xs:
    case Nil{}:
      d
    case Con{h, t}:
      last(t, h)

# One unit of capacity, so x completes before y starts.
def run(+path: String) -> IO(Unit):
  +log = path ++ ".log"
  do IO<Unit>:
    r0 : R.Runner<String> <- IO.try(R.Runner<String>, R.open(~String, ~penc, ~pdec, path, 4096, 1048576, config(), 1n))
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|ok:x")
    r2 : R.Runner<String> <- enq(r1, 1n, log ++ "|crash:y")
    y : R.Ran(String) <- R.drain(~String, ~penc, ~target, ~work, 100n, r2)
    IO.die(Unit, 1, "crash: the attempt did not kill the process")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(last(args, ""))
