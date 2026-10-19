import Base
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
import bend-kit-journal@0.2.0.0/journal.bend as J
import bend-kit-retry@0.1.0.0/retry.bend as Retry
import bend-kit-scheduler@0.3.0.0/queue.bend as Q
import bend-kit-files@0.2.0.0/files.bend as Files
import bend-kit-collections@0.1.3.0/heap.bend as H
import bend-kit-collections@0.1.3.0/omap.bend as O
import ./runner.bend as R
import ./example.bend as Example

def ok(good: Bool, +name: String) -> IO(Unit):
  match good:
    case True{}:
      IO.print("ok " ++ name)
    case False{}:
      IO.die(Unit, 1, "bad " ++ name)

def same.if(eq: Bool, +got: String, +want: String, +name: String) -> IO(Unit):
  match eq:
    case True{}:
      IO.print("ok " ++ name)
    case False{}:
      IO.die(Unit, 1, "bad " ++ name ++ ": got " ++ got ++ ", want " ++ want)

def same(+got: String, +want: String, +name: String) -> IO(Unit):
  same.if(String.eq(got, want), got, want, name)

# ---- a String payload, as its octets

def penc(s: String) -> Bytes.Bytes:
  Bytes.from_string(s)

def pdec(b: Bytes.Bytes) -> Maybe<&2, String>:
  Some{Bytes.to_string(b)}

def show(m: Maybe<&2, R.Op<String>>) -> String:
  match m:
    case None{}:
      "none"
    case Some{R.Enqueue{d, x}}:
      "enqueue " ++ Nat.show(d) ++ " " ++ x
    case Some{R.Select{n}}:
      "select " ++ Nat.show(n)
    case Some{R.Complete{i}}:
      "complete " ++ Nat.show(i)
    case Some{R.Cancel{i}}:
      "cancel " ++ Nat.show(i)
    case Some{R.Requeue{i, d}}:
      "requeue " ++ Nat.show(i) ++ " " ++ Nat.show(d)
    case Some{R.Defer{i, d}}:
      "defer " ++ Nat.show(i) ++ " " ++ Nat.show(d)

def rt(+op: R.Op<String>) -> String:
  show(R.decode(~String, ~pdec, R.encode(~String, ~penc, op)))

def big() -> Nat:
  Nat.add(Nat.mul(1700n, 1000000000n), 123n)

def live(ops: List<&2, R.Op<String>>, s: R.State<String>) -> R.State<String>:
  match ops:
    case Nil{}:
      s
    case Con{op, rest}:
      live(rest, R.step(~String, s, op))

# Two tickets pending, two running, one requeued once, one cancelled.
def sample() -> R.State<String>:
  live([R.Enqueue{5n, "a"}, R.Enqueue{big(), "b|c"}, R.Enqueue{3n, ""}, R.Select{10n}, R.Requeue{2n, 20n}, R.Select{30n}, R.Enqueue{1n, "d"},
    R.Enqueue{40n, "e"}, R.Cancel{4n}, R.Select{30n}], R.new(String))

def hex(s: R.State<String>) -> String:
  Bytes.to_hex(R.encode.snap(~String, ~penc, s))

def shown.rec(m: Maybe<&2, R.Rec<String>>) -> String:
  match m:
    case None{}:
      "none"
    case Some{R.Snap{s}}:
      hex(s)
    case Some{R.Do{op}}:
      "op " ++ show(Some{op})

def rec(b: Bytes.Bytes) -> String:
  shown.rec(R.decode.rec(~String, ~pdec, b))

def fails(ts: List<&1, Nat & R.Try>) -> Nat:
  match ts:
    case Nil{}:
      0n
    case Con{(i, R.Try{f, st}), rest}:
      Nat.add(f, fails(rest))

def describe(s: R.State<String>) -> String:
  R.State{Q.State{+n, +h, +run}, +ts} = s
  "next=" ++ Nat.show(n) ++ " pending=" ++ Nat.show(R.pending(String, R.State{Q.State{n, h, run}, ts})) ++ " running=" ++ Nat.show(List.length(&2, Q.Ticket<String>, run)) ++
    " tries=" ++ U32.show(O.OMap.size(Nat, R.Try, ts)) ++ " fails=" ++ Nat.show(fails(O.OMap.to_list(Nat, R.Try, ts)))

def snapshots() -> IO(Unit):
  do IO<Unit>:
    same(describe(sample()), "next=5 pending=2 running=2 tries=4 fails=1", "the sample state has pending, running, and retried tickets")
    same(rec(R.encode.snap(~String, ~penc, sample())), hex(sample()), "a snapshot decodes to the same heap, running list, and tries")
    same(rec(R.encode.snap(~String, ~penc, R.new(String))), hex(R.new(String)), "an empty snapshot round-trips")
    same(rec(R.encode(~String, ~penc, R.Cancel{8n})), "op cancel 8", "an op record decodes as an op")
    same(rec(Bytes.snd(Bytes.slice(R.encode.snap(~String, ~penc, sample()), 0, 60))), "none", "a short snapshot does not decode")
    same(rec(Bytes.append(R.encode.snap(~String, ~penc, sample()), Bytes.new(4))), "none", "a snapshot with octets after it does not decode")
    same(rec(Bytes.set(R.encode.snap(~String, ~penc, sample()), 12, 2)), "none", "a snapshot flag other than 0 or 1 does not decode")

def codec() -> IO(Unit):
  +t = big()
  do IO<Unit>:
    same(rt(R.Enqueue{t, "a|b"}), "enqueue 1700000000123 a|b", "an Enqueue keeps a 41-bit deadline and its payload")
    same(rt(R.Enqueue{0n, ""}), "enqueue 0 ", "an Enqueue keeps an empty payload")
    same(rt(R.Select{t}), "select 1700000000123", "a Select keeps its now")
    same(rt(R.Complete{7n}), "complete 7", "a Complete keeps its id")
    same(rt(R.Cancel{8n}), "cancel 8", "a Cancel keeps its id")
    same(rt(R.Requeue{9n, t}), "requeue 9 1700000000123", "a Requeue keeps its id and deadline")
    same(rt(R.Defer{10n, t}), "defer 10 1700000000123", "a Defer keeps its id and deadline")
    same(show(R.decode(~String, ~pdec, Bytes.from_string("abc"))), "none", "a record shorter than a head is not an op")
    same(show(R.decode(~String, ~pdec, Bytes.set(R.encode(~String, ~penc, R.Cancel{8n}), 0, 9))), "none", "an unknown tag is not an op")
    same(show(R.decode(~String, ~pdec, Bytes.snd(Bytes.slice(R.encode(~String, ~penc, R.Cancel{8n}), 0, 16)))), "none", "a short Cancel is not an op")

# ---- jobs: "log|kind:name". work notes the job in log, runs it, then notes "end" and the job, and answers by kind.
# A slow job sleeps 1 s before it ends.
def note.close(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, x) = r
  File.close(f)

def note(+log: String, +spec: String) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(log, "a"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, spec ++ "\n")
    note.close(r)

def outcome(+spec: String) -> Retry.Outcome:
  Bool.pick(Retry.Outcome, String.starts_with(spec, "fail:"), Retry.Transient{Some{0n}}, Retry.Settled{})

def work.go(xs: List<&2, String>) -> IO(Retry.Outcome):
  match xs:
    case Con{+log, Con{+spec, Nil{}}}:
      do IO<Retry.Outcome>:
        note(log, spec)
        IO.sleep(Bool.pick(U32, String.starts_with(spec, "slow:"), 1000, 0))
        note(log, "end " ++ spec)
        return outcome(spec)
    case _:
      IO.pure(Retry.Outcome, Retry.Settled{})

def work(s: String) -> IO(Retry.Outcome):
  work.go(String.split(s, '|'))

# Every job has one breaker; a failing one opens it after two failures.
def target(s: String) -> String:
  "local"

def config(+threshold: Nat, +every: U32) -> R.Config:
  R.Config{Retry.Policy{3n, 1n, 4, None{}}, Retry.Circuit{threshold, 60000n, 60000n, 1n}, 5, every}

def opened.every(+path: String, +threshold: Nat, +every: U32, +max: U32) -> IO(R.Runner<String>):
  IO.try(R.Runner<String>, R.open(~String, ~penc, ~pdec, path, max, 1048576, config(threshold, every), 2n))

def opened(+path: String, +threshold: Nat) -> IO(R.Runner<String>):
  opened.every(path, threshold, 0, 4096)

def enq.got(y: R.Runner<String> & R.Out(Nat)) -> IO(R.Runner<String>):
  match y:
    case (r, Done{i}):
      IO.pure(R.Runner<String>, r)
    case (r, Fail{(c, m)}):
      IO.die(R.Runner<String>, 1, "bad enqueue: " ++ m)

def enq(r: R.Runner<String>, +d: Nat, +x: String) -> IO(R.Runner<String>):
  do IO<R.Runner<String>>:
    y : R.Runner<String> & R.Out(Nat) <- R.enqueue(~String, ~penc, r, d, x)
    enq.got(y)

def ran(y: R.Ran(String)) -> IO(R.Runner<String>):
  match y:
    case (r, Done{u}):
      IO.pure(R.Runner<String>, r)
    case (r, Fail{(c, m)}):
      IO.die(R.Runner<String>, 1, "bad drain: " ++ m)

def drain(r: R.Runner<String>) -> IO(R.Runner<String>):
  do IO<R.Runner<String>>:
    y : R.Ran(String) <- R.drain(~String, ~penc, ~target, ~work, 400n, r)
    ran(y)

def count(xs: List<&2, String>, +x: String) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+h, t}:
      Nat.add(Bool.pick(Nat, String.eq(h, x), 1n, 0n), count(t, x))

def read.got(r: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  match r:
    case (f, Done{s}):
      do IO<String>:
        File.close(f)
        return s
    case (f, Fail{(c, m)}):
      do IO<String>:
        File.close(f)
        IO.die(String, 1, "bad read: " ++ m)

def read(+path: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & Result<&1, &1, U32 & String, String> <- File.read(f, 65536)
    s : String <- read.got(r)
    return String.split(s, '\n')

def counts(xs: List<&2, String>, ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{+k, rest}:
      +ys = xs
      k ++ "=" ++ Nat.show(count(ys, k)) ++ " " ++ counts(ys, rest)

def view.of(x: R.Runner<String> & R.State<String>) -> R.Runner<String> & String:
  (r, s) = x
  (r, describe(s))

def view(r: R.Runner<String>) -> R.Runner<String> & String:
  view.of(R.state(String, r))

def closed(+want: String, +name: String, x: R.Runner<String> & String) -> IO(Unit):
  (r, got) = x
  do IO<Unit>:
    same(got, want, name)
    R.close(String, r)

# Three jobs: two succeed once; one fails every time and stops after the policy's 3 attempts.
def durable(+dir: String) -> IO(Unit):
  +path = dir ++ "/jobs.journal"
  +log = dir ++ "/jobs.log"
  do IO<Unit>:
    r0 : R.Runner<String> <- opened(path, 100n)
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|ok:a")
    r2 : R.Runner<String> <- enq(r1, 0n, log ++ "|fail:b")
    r3 : R.Runner<String> <- enq(r2, 0n, log ++ "|ok:c")
    r4 : R.Runner<String> <- drain(r3)
    closed("next=3 pending=0 running=0 tries=0 fails=0", "drain completes every job and drops its tries", view(r4))
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["ok:a", "fail:b", "ok:c"]), "ok:a=1 fail:b=3 ok:c=1 ", "a job runs once; a failing job runs the policy's 3 attempts")
    r5 : R.Runner<String> <- opened(path, 100n)
    closed("next=3 pending=0 running=0 tries=0 fails=0", "reopen replays the same state", view(r5))

def status(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> U32:
  match r:
    case Done{(s, o)}:
      s
    case Fail{e}:
      0

def held(x: R.Runner<String> & String, +want: String, +name: String) -> IO(R.Runner<String>):
  (r, got) = x
  do IO<R.Runner<String>>:
    same(got, want, name)
    return r

# A child completes x, then dies inside y's attempt. On reopen y runs again, and x does not.
def crash(+dir: String) -> IO(Unit):
  +path = dir ++ "/crash.journal"
  +log = path ++ ".log"
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("bend", ["crash.bend", "attempt", path], "", 65536, 120000)
    ok(U32.is_eq(status(c), 9), "the child dies inside an attempt")
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["ok:x", "crash:y"]), "ok:x=1 crash:y=1 ", "the child ran x, then started y")
    r0 : R.Runner<String> <- opened(path, 100n)
    r1 : R.Runner<String> <- held(view(r0), "next=2 pending=1 running=0 tries=1 fails=1", "reopen requeues the running y as a failed attempt, and x stays complete")
    r2 : R.Runner<String> <- drain(r1)
    closed("next=2 pending=0 running=0 tries=0 fails=0", "the requeued y completes", view(r2))
    ys : List<&2, String> <- read(log)
    same(counts(ys, ["ok:x", "crash:y"]), "ok:x=1 crash:y=2 ", "y runs again after the crash, and the completed x does not")

def left(y: R.Ran(String)) -> IO(R.Runner<String>):
  match y:
    case (r, Fail{(c, m)}):
      do IO<R.Runner<String>>:
        same(m, "runner: drain ran out of rounds", "drain stops while the breaker holds the jobs back")
        return r
    case (r, Done{u}):
      IO.die(R.Runner<String>, 1, "bad breaker: drain finished while the breaker was open")

def root(-A: Data, h: H.Heap<Q.Ticket<A>>) -> Nat:
  match h:
    case H.HLeaf{}:
      0n
    case H.HNode{n, t, l, r}:
      Q.deadline(A, t)

def deferred(+now: Nat, x: R.Runner<String> & R.State<String>) -> IO(R.Runner<String>):
  (r, s) = x
  R.State{q, ts} = s
  do IO<R.Runner<String>>:
    ok(Nat.is_le(Nat.add(now, 50000n), root(String, Q.pending(String, q))), "a held job waits for the breaker's cooldown")
    return r

# Two jobs of one target fail at once. The first failure opens the breaker, so no third attempt starts.
def breaker(+dir: String) -> IO(Unit):
  +path = dir ++ "/breaker.journal"
  +log = dir ++ "/breaker.log"
  do IO<Unit>:
    r0 : R.Runner<String> <- opened(path, 1n)
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|fail:p")
    r2 : R.Runner<String> <- enq(r1, 0n, log ++ "|fail:q")
    y : R.Ran(String) <- R.drain(~String, ~penc, ~target, ~work, 20n, r2)
    r3 : R.Runner<String> <- left(y)
    now : Nat <- R.clock()
    r4 : R.Runner<String> <- deferred(now, R.state(String, r3))
    closed("next=2 pending=2 running=0 tries=2 fails=2", "a deferral counts no failure", view(r4))
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["fail:p", "fail:q"]), "fail:p=1 fail:q=1 ", "an open breaker starts no attempt")

def stat.size(r: Result<&1, &1, U32 & String, Files.Info>) -> U32:
  match r:
    case Done{Files.Info{k, n, t}}:
      n
    case Fail{e}:
      0

def size(+path: String) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, Files.Info> <- Files.stat(path)
    return stat.size(r)

def compacted(y: R.Ran(String)) -> IO(R.Runner<String>):
  match y:
    case (r, Done{u}):
      IO.pure(R.Runner<String>, r)
    case (r, Fail{(c, m)}):
      IO.die(R.Runner<String>, 1, "bad compact: " ++ m)

# The runner back, and the hex of its state's snapshot: equal hex means an equal state.
def state.hex(x: R.Runner<String> & R.State<String>) -> R.Runner<String> & String:
  (r, s) = x
  (r, hex(s))

def closed.hex(x: R.Runner<String> & String) -> IO(String):
  (r, h) = x
  do IO<String>:
    R.close(String, r)
    return h

def len.of(r: Bytes.Bytes & U32) -> U32:
  (b, n) = r
  n

def state.size(x: R.Runner<String> & R.State<String>) -> R.Runner<String> & String:
  (r, s) = x
  (r, U32.show((12 + len.of(Bytes.length(R.encode.snap(~String, ~penc, s))) : U32)))

def far() -> Nat:
  Nat.mul(4000n, 1000000000n)

# Three jobs drain, a fourth waits; compaction keeps only the live state, and reopen replays it, then the records after it.
# max fits the longest op record, 12 octets and the payload, and the snapshot of one waiting job does not fit it.
def compaction(+dir: String) -> IO(Unit):
  +path = dir ++ "/compact.journal"
  +log = dir ++ "/compact.log"
  +max = (Bytes.count(log, 0) + 19 : U32)
  do IO<Unit>:
    r0 : R.Runner<String> <- opened.every(path, 100n, 0, max)
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|ok:a")
    r2 : R.Runner<String> <- enq(r1, 0n, log ++ "|fail:b")
    r3 : R.Runner<String> <- enq(r2, 0n, log ++ "|ok:c")
    r4 : R.Runner<String> <- drain(r3)
    r5 : R.Runner<String> <- enq(r4, far(), log ++ "|ok:d")
    before : U32 <- size(path)
    y : R.Ran(String) <- R.compact(~String, ~penc, r5)
    r6 : R.Runner<String> <- compacted(y)
    +after : U32 <- size(path)
    ok(U32.is_lt(after, before), "compaction shrinks the journal")
    ok(U32.is_gt(after, (max + 12 : U32)), "the snapshot is larger than max")
    left : Bool <- Files.exists(path ++ ".compact")
    ok(Bool.not(left), "compaction leaves no temporary file")
    r7 : R.Runner<String> <- enq(r6, far(), log ++ "|ok:e")
    want : String <- closed.hex(state.hex(R.state(String, r7)))
    r8 : R.Runner<String> <- opened.every(path, 100n, 0, max)
    r9 : R.Runner<String> <- held(state.hex(R.state(String, r8)), want, "reopen replays the snapshot and the records after it to the same state")
    closed("next=5 pending=2 running=0 tries=2 fails=0", "the compacted journal keeps the waiting jobs and drops the finished ones", view(r9))
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["ok:a", "fail:b", "ok:c"]), "ok:a=1 fail:b=3 ok:c=1 ", "no finished job runs again after compaction")

# compact = 1: every tick compacts, so after the drain the journal is one snapshot frame.
def compaction.auto(+dir: String) -> IO(Unit):
  +path = dir ++ "/auto.journal"
  +log = dir ++ "/auto.log"
  do IO<Unit>:
    r0 : R.Runner<String> <- opened.every(path, 100n, 1, 4096)
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|ok:a")
    r2 : R.Runner<String> <- enq(r1, 0n, log ++ "|fail:b")
    r3 : R.Runner<String> <- drain(r2)
    n : U32 <- size(path)
    r4 : R.Runner<String> <- held(state.size(R.state(String, r3)), U32.show(n), "the journal is one frame that holds the snapshot")
    closed("next=2 pending=0 running=0 tries=0 fails=0", "tick compacts and keeps the state", view(r4))
    r5 : R.Runner<String> <- opened(path, 100n)
    closed("next=2 pending=0 running=0 tries=0 fails=0", "reopen after automatic compaction replays the same state", view(r5))

def found.hex(m: Maybe<&2, R.State<String>>) -> String:
  match m:
    case None{}:
      "none"
    case Some{s}:
      hex(s)

def found(m: J.Journal & Maybe<&2, R.State<String>>) -> IO(String):
  (j, s) = m
  do IO<String>:
    J.close(j)
    return found.hex(s)

# The state in the snapshot file that a crashed compaction left behind.
def snapshot.hex(+path: String) -> IO(String):
  do IO<String>:
    m : J.Journal & Maybe<&2, R.State<String>> <- IO.try(J.Journal & Maybe<&2, R.State<String>>,
      J.open(~Maybe<&2, R.State<String>>, ~(a => b => R.replay.step(~String, ~pdec, a, b)), path, 1048576, 1048576, Some{R.new(String)}))
    found(m)

# A child completes x, writes the snapshot, and dies before the rename. Reopen gives the state of the snapshot, and x does not run again.
def crash.snapshot(+dir: String) -> IO(Unit):
  +path = dir ++ "/snap.journal"
  +log = path ++ ".log"
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("bend", ["crash.bend", "snapshot", path], "", 65536, 120000)
    ok(U32.is_eq(status(c), 9), "the child dies after the snapshot is durable and before the rename")
    +want : String <- snapshot.hex(path ++ ".compact")
    r0 : R.Runner<String> <- opened(path, 100n)
    r1 : R.Runner<String> <- held(state.hex(R.state(String, r0)), want, "reopen after a crash inside compaction gives the same state")
    y : R.Ran(String) <- R.compact(~String, ~penc, r1)
    r2 : R.Runner<String> <- compacted(y)
    R.close(String, r2)
    r3 : R.Runner<String> <- opened(path, 100n)
    r4 : R.Runner<String> <- held(state.hex(R.state(String, r3)), want, "a later compaction replaces the stale snapshot and keeps the state")
    r5 : R.Runner<String> <- held(view(r4), "next=2 pending=1 running=0 tries=1 fails=0", "x stays complete, and y waits")
    z : R.Ran(String) <- R.cancel(~String, ~penc, r5, 1n)
    r6 : R.Runner<String> <- ran(z)
    r7 : R.Runner<String> <- drain(r6)
    R.close(String, r7)
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["ok:x", "ok:y"]), "ok:x=1 ok:y=0 ", "the completed x does not run again")

# A child completes x, compacts, then dies inside z's attempt. Reopen replays the snapshot and z's records, and requeues z.
def crash.compacted(+dir: String) -> IO(Unit):
  +path = dir ++ "/compacted.journal"
  +log = path ++ ".log"
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("bend", ["crash.bend", "compacted", path], "", 65536, 120000)
    ok(U32.is_eq(status(c), 9), "the child dies inside an attempt after compaction")
    r0 : R.Runner<String> <- opened(path, 100n)
    r1 : R.Runner<String> <- held(view(r0), "next=2 pending=1 running=0 tries=1 fails=1", "reopen requeues the running z, and x stays complete")
    r2 : R.Runner<String> <- drain(r1)
    R.close(String, r2)
    xs : List<&2, String> <- read(log)
    same(counts(xs, ["ok:x", "crash:z"]), "ok:x=1 crash:z=2 ", "z runs again after the crash, and the completed x does not")

def ticked(t: R.Runner<String> & R.Out(Bool)) -> IO(R.Runner<String>):
  match t:
    case (r, Done{b}):
      IO.pure(R.Runner<String>, r)
    case (r, Fail{(c, m)}):
      IO.die(R.Runner<String>, 1, "bad tick: " ++ m)

# The most attempts that run at once in a log: a job line starts one, and an "end" line ends one.
def peak(xs: List<&2, String>, +cur: Nat, +best: Nat) -> Nat:
  match xs:
    case Nil{}:
      best
    case Con{+h, t}:
      +c = Bool.pick(Nat, String.starts_with(h, "end "), Nat.sub(cur, 1n), Bool.pick(Nat, String.eq(h, ""), cur, Nat.add(cur, 1n)))
      peak(t, c, Bool.pick(Nat, Nat.is_lt(best, c), c, best))

def last(xs: List<&2, String>, +acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{+h, t}:
      last(t, Bool.pick(String, String.eq(h, ""), acc, h))

# Capacity 2: a slow job and five fast jobs. One tick runs them all, and the fast jobs finish in the free unit while the slow one runs.
def overlap(+dir: String) -> IO(Unit):
  +path = dir ++ "/overlap.journal"
  +log = dir ++ "/overlap.log"
  do IO<Unit>:
    r0 : R.Runner<String> <- opened(path, 100n)
    r1 : R.Runner<String> <- enq(r0, 0n, log ++ "|slow:s")
    r2 : R.Runner<String> <- enq(r1, 0n, log ++ "|ok:f1")
    r3 : R.Runner<String> <- enq(r2, 0n, log ++ "|ok:f2")
    r4 : R.Runner<String> <- enq(r3, 0n, log ++ "|ok:f3")
    r5 : R.Runner<String> <- enq(r4, 0n, log ++ "|ok:f4")
    r6 : R.Runner<String> <- enq(r5, 0n, log ++ "|ok:f5")
    t : R.Runner<String> & R.Out(Bool) <- R.tick(~String, ~penc, ~target, ~work, r6)
    r7 : R.Runner<String> <- ticked(t)
    closed("next=6 pending=0 running=0 tries=0 fails=0", "one tick runs a slow job and five fast jobs", view(r7))
    +ys : List<&2, String> <- read(log)
    same(Nat.show(peak(ys, 0n, 0n)), "2", "no more attempts run at once than the capacity")
    same(last(ys, ""), "end slow:s", "the fast jobs finish while the slow job runs")

def all(+dir: String) -> IO(Unit):
  do IO<Unit>:
    durable(dir)
    crash(dir)
    breaker(dir)
    overlap(dir)
    compaction(dir)
    compaction.auto(dir)
    crash.snapshot(dir)
    crash.compacted(dir)
    Example.run(dir ++ "/hooks.journal")

def main() -> IO(Unit):
  do IO<Unit>:
    codec()
    snapshots()
    dir : String <- IO.try(String, Files.temp_dir())
    all(dir)
