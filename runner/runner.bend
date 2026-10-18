# Durable job runner: a journaled scheduler queue, bounded by a resources pool, with retry and a breaker per target. Source: https://github.com/paymog/bend-kit/tree/main/runner
import Base
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
import bend-kit-journal@0.2.0.0/journal.bend as J
import bend-kit-scheduler@0.3.0.0/queue.bend as Q
import bend-kit-resources@0.1.0.0/resources.bend as Res
import bend-kit-retry@0.1.0.0/retry.bend as Retry
import bend-kit-time@0.2.0.0/time.bend as Time
import bend-kit-collections@0.1.3.0/heap.bend as H
import bend-kit-collections@0.1.3.0/omap.bend as O

# One queue transition. Each one is one journal record, appended before the state changes.
# Select: the queue's select at now. Replay runs it at the same now, so it takes the same ticket.
# Requeue: the attempt failed; it counts one failure. Defer: the breaker held the ticket back; no attempt ran.
type Op<-A: Data> is Data:
  Enqueue{deadline: Nat, payload: A}
  Select{now: Nat}
  Complete{id: Nat}
  Cancel{id: Nat}
  Requeue{id: Nat, deadline: Nat}
  Defer{id: Nat, deadline: Nat}

# The failed attempts of a ticket, and its first deadline, from which the policy deadline counts.
type Try is Data:
  Try{fails: Nat, start: Nat}

# A Try for each ticket that is not yet complete or cancelled, by ticket id.
def Tries() -> Data:
  O.OMap<Nat, Try>

# The durable state: the queue and the tries.
type State<-A: Data> is Data:
  State{queue: Q.State<A>, tries: Tries()}

def new(-A: Data) -> State<A>:
  State{Q.new(A), O.OMap.new(Nat, Try)}

def queue(-A: Data, s: State<A>) -> Q.State<A>:
  State{q, ts} = s
  q

def tries(-A: Data, s: State<A>) -> Tries():
  State{q, ts} = s
  ts

# ---- tries

def tries.drop(ts: Tries(), +i: Nat) -> Tries():
  O.OMap.del(~Nat, ~Try, ~Nat.cmp, ts, i)

def tries.get(ts: Tries(), +i: Nat) -> Maybe<&2, Try>:
  O.OMap.get(~Nat, ~Try, ~Nat.cmp, ts, i)

def tries.bump.got(m: Maybe<&2, Try>, ts: Tries(), +i: Nat) -> Tries():
  match m:
    case None{}:
      ts
    case Some{Try{f, st}}:
      O.OMap.put(~Nat, ~Try, ~Nat.cmp, ts, i, Try{1n+f, st})

def tries.bump(+ts: Tries(), +i: Nat) -> Tries():
  tries.bump.got(tries.get(ts, i), ts, i)

# ---- the transition

def step.enqueued(-A: Data, r: Q.State<A> & Nat, ts: Tries(), d: Nat) -> State<A>:
  (q, i) = r
  State{q, O.OMap.put(~Nat, ~Try, ~Nat.cmp, ts, i, Try{0n, d})}

def step.selected(-A: Data, r: Q.State<A> & Maybe<&2, Q.Ticket<A>>, ts: Tries()) -> State<A>:
  (q, t) = r
  State{q, ts}

def step.requeued(-A: Data, r: Q.State<A> & Bool, ts: Tries()) -> State<A>:
  (q, b) = r
  State{q, ts}

# Complete takes the ticket from the running list only: O(running), not O(pending).
def step.completed(-A: Data, r: Q.State<A> & Maybe<&2, Q.Ticket<A>>, ts: Tries()) -> State<A>:
  (q, t) = r
  State{q, ts}

# The state after op. Live and replay both run it, so they agree.
def step(~A: Data, s: State<A>, op: Op<A>) -> State<A>:
  match s op:
    case State{q, ts} Enqueue{+d, x}:
      step.enqueued(A, Q.enqueue(~A, d, x, q), ts, d)
    case State{q, ts} Select{now}:
      step.selected(A, Q.select(~A, now, q), ts)
    case State{q, ts} Complete{+i}:
      step.completed(A, Q.complete(A, i, q), tries.drop(ts, i))
    case State{q, ts} Cancel{+i}:
      State{Q.cancel(~A, i, q), tries.drop(ts, i)}
    case State{q, ts} Requeue{+i, d}:
      step.requeued(A, Q.requeue(~A, i, d, q), tries.bump(ts, i))
    case State{q, ts} Defer{i, d}:
      step.requeued(A, Q.requeue(~A, i, d, q), ts)

def apply.op(~A: Data, m: Maybe<&2, Op<A>>, s: State<A>) -> Maybe<&2, State<A>>:
  match m:
    case None{}:
      None{}
    case Some{op}:
      Some{step(~A, s, op)}

# Folds one record into the replayed state. A record that does not decode ends the replay with None.
def apply(~A: Data, ~R: Type, ~dec: R -> Maybe<&2, Op<A>>, acc: Maybe<&2, State<A>>, r: R) -> Maybe<&2, State<A>>:
  match acc:
    case None{}:
      None{}
    case Some{s}:
      apply.op(~A, dec(r), s)

# ---- pool

# Picked: a due ticket and one unit of the pool for it. Idle: no due ticket, or no free unit; the pool is unchanged.
type Pick<-A: Data> is Type:
  Picked{pool: Res.Pool, ticket: Q.Ticket<A>, grant: Res.Grant}
  Idle{pool: Res.Pool}

def pick.took(-A: Data, r: Res.Reserve, t: Q.Ticket<A>) -> Pick<A>:
  match r:
    case Res.Took{p, g}:
      Picked{p, t, g}
    case Res.Refused{p}:
      Idle{p}

def pick.due(-A: Data, m: Maybe<&2, Q.Ticket<A>>, p: Res.Pool) -> Pick<A>:
  match m:
    case None{}:
      Idle{p}
    case Some{t}:
      pick.took(A, Res.reserve(p, 1n), t)

def pick.sel(-A: Data, r: Q.State<A> & Maybe<&2, Q.Ticket<A>>, p: Res.Pool) -> Pick<A>:
  (q, m) = r
  pick.due(A, m, p)

# The ticket that Select{now} takes, with one unit of p, when there is a ticket due and a unit free.
def pick(~A: Data, p: Res.Pool, s: State<A>, now: Nat) -> Pick<A>:
  State{q, ts} = s
  pick.sel(A, Q.select(~A, now, q), p)

# ---- retry

# The budget left for ticket i: the policy's attempts less its failures, until its start plus the policy deadline.
def budget.of(+attempts: Nat, t: Maybe<&2, Try>, d: Maybe<&2, Nat>) -> Retry.Budget:
  match t d:
    case None{} m:
      Retry.Budget{attempts, None{}}
    case Some{Try{f, st}} None{}:
      Retry.Budget{Nat.sub(attempts, f), None{}}
    case Some{Try{f, +st}} Some{ms}:
      Retry.Budget{Nat.sub(attempts, f), Some{Nat.add(st, ms)}}

def budget(p: Retry.Policy, t: Maybe<&2, Try>) -> Retry.Budget:
  Retry.Policy{a, base, cap, d} = p
  budget.of(a, t, d)

# The failures so far: the index of the next retry.
def fails(t: Maybe<&2, Try>) -> Nat:
  match t:
    case None{}:
      0n
    case Some{Try{f, st}}:
      f

def after.plan(-A: Data, pl: Retry.Plan, +id: Nat, +now: Nat) -> Op<A>:
  match pl:
    case Retry.PlanStop{}:
      Complete{id}
    case Retry.PlanWait{w}:
      Requeue{id, Nat.add(now, w)}

# The record after an attempt of ticket id ends at now with o: requeue at now plus retry's wait, or complete.
def after(-A: Data, o: Retry.Outcome, p: Retry.Policy, b: Retry.Budget, +id: Nat, +n: Nat, +now: Nat, +r: Nat) -> Op<A>:
  after.plan(A, Retry.plan(o, p, b, n, now, r), id, now)

# When an open breaker lets attempts start again.
def until(br: Retry.Breaker, +now: Nat) -> Nat:
  match br:
    case Retry.BreakerOn{c, Retry.CircuitOpen{u}}:
      u
    case Retry.BreakerOn{c, Retry.CircuitClosed{fs}}:
      Nat.add(now, Retry.Circuit.cooldown(c))
    case Retry.BreakerOn{c, Retry.CircuitHalf{k}}:
      Nat.add(now, Retry.Circuit.cooldown(c))
    case Retry.BreakerOff{}:
      now

# The record for a ticket that admit refused: Defer to when the breaker may admit, or Complete when its budget is spent or late.
def held(-A: Data, why: Retry.Deny, br: Retry.Breaker, +id: Nat, +now: Nat) -> Op<A>:
  match why:
    case Retry.DenyOpen{}:
      Defer{id, until(br, now)}
    case Retry.DenyLate{}:
      Complete{id}
    case Retry.DenySpent{}:
      Complete{id}

# ---- the record codec: a u32le tag, then u64le fields; an Enqueue then holds the payload.

def W() -> Nat:
  Nat.mul(65536n, 65536n)

# Nat fields hold values under 2^64.
def put.u64(b: Bytes.Bytes, +at: U32, +n: Nat) -> Bytes.Bytes:
  Bytes.set.u32le(Bytes.set.u32le(b, at, U32.from_nat(Nat.mod(n, W()))), (at + 4 : U32), U32.from_nat(Nat.div(n, W())))

def head(+tag: U32, +a: Nat, +c: Nat) -> Bytes.Bytes:
  put.u64(put.u64(Bytes.set.u32le(Bytes.new(20), 0, tag), 4, a), 12, c)

def encode(~A: Data, ~penc: A -> Bytes.Bytes, op: Op<A>) -> Bytes.Bytes:
  match op:
    case Enqueue{+d, x}:
      Bytes.append(put.u64(Bytes.set.u32le(Bytes.new(12), 0, 1), 4, d), penc(x))
    case Select{+now}:
      head(2, now, 0n)
    case Complete{+i}:
      head(3, i, 0n)
    case Cancel{+i}:
      head(4, i, 0n)
    case Requeue{+i, +d}:
      head(5, i, d)
    case Defer{+i, +d}:
      head(6, i, d)

def get.field(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      x

def get.u32(r: Bytes.Bytes & Maybe<&2, U32>) -> Bytes.Bytes & U32:
  (b, m) = r
  (b, get.field(m))

def get.hi(+lo: U32, r: Bytes.Bytes & Maybe<&2, U32>) -> Bytes.Bytes & Nat:
  (b, m) = r
  (b, Nat.add(U32.to_nat(lo), Nat.mul(U32.to_nat(get.field(m)), W())))

def get.lo(+at: U32, r: Bytes.Bytes & Maybe<&2, U32>) -> Bytes.Bytes & Nat:
  (b, m) = r
  +lo = get.field(m)
  get.hi(lo, Bytes.get.u32le(b, (at + 4 : U32)))

def get.u64(b: Bytes.Bytes, +at: U32) -> Bytes.Bytes & Nat:
  get.lo(at, Bytes.get.u32le(b, at))

def decode.small(-A: Data, ok: Bool, +tag: U32, +a: Nat, +c: Nat) -> Maybe<&2, Op<A>>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Bool.pick(Maybe<&2, Op<A>>, U32.is_eq(tag, 2), Some{Select{a}},
      Bool.pick(Maybe<&2, Op<A>>, U32.is_eq(tag, 3), Some{Complete{a}},
      Bool.pick(Maybe<&2, Op<A>>, U32.is_eq(tag, 4), Some{Cancel{a}},
      Bool.pick(Maybe<&2, Op<A>>, U32.is_eq(tag, 5), Some{Requeue{a, c}},
      Bool.pick(Maybe<&2, Op<A>>, U32.is_eq(tag, 6), Some{Defer{a, c}}, None{})))))

def decode.payload(-A: Data, m: Maybe<&2, A>, +d: Nat) -> Maybe<&2, Op<A>>:
  match m:
    case None{}:
      None{}
    case Some{x}:
      Some{Enqueue{d, x}}

def decode.c(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, +tag: U32, +len: U32, +a: Nat, r: Bytes.Bytes & Nat) -> Maybe<&2, Op<A>>:
  (b, +c) = r
  decode.small(A, U32.is_eq(len, 20), tag, a, c)

def decode.kind(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, enq: Bool, +tag: U32, +len: U32, +a: Nat, b: Bytes.Bytes) -> Maybe<&2, Op<A>>:
  match enq:
    case True{}:
      decode.payload(A, pdec(Bytes.snd(Bytes.slice(b, 12, (len - 12 : U32)))), a)
    case False{}:
      decode.c(~A, ~pdec, tag, len, a, get.u64(b, 12))

def decode.a(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, +tag: U32, +len: U32, r: Bytes.Bytes & Nat) -> Maybe<&2, Op<A>>:
  (b, +a) = r
  decode.kind(~A, ~pdec, U32.is_eq(tag, 1), tag, len, a, b)

def decode.tag(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, +len: U32, r: Bytes.Bytes & U32) -> Maybe<&2, Op<A>>:
  (b, +tag) = r
  decode.a(~A, ~pdec, tag, len, get.u64(b, 4))

def decode.len(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, ok: Bool, +len: U32, b: Bytes.Bytes) -> Maybe<&2, Op<A>>:
  match ok:
    case False{}:
      None{}
    case True{}:
      decode.tag(~A, ~pdec, len, get.u32(Bytes.get.u32le(b, 0)))

# The op of a record, or None when it is not one that encode writes.
def decode(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, b: Bytes.Bytes) -> Maybe<&2, Op<A>>:
  Bytes.Bytes{+len, buf} = b
  decode.len(~A, ~pdec, U32.is_ge(len, 12), len, Bytes.Bytes{len, buf})

# ---- the runner

# policy: retry's policy for each ticket. circuit: the breaker of each target. idle: ms that drain waits when no attempt started.
type Config is Data:
  Config{policy: Retry.Policy, circuit: Retry.Circuit, idle: U32}

# An open runner. Its journal holds every op that made state; its pool bounds the attempts that run at once.
type Runner<-A: Data> is Type:
  Runner{journal: J.Journal, state: State<A>, pool: Res.Pool, breakers: Map<&2, Retry.Breaker>, config: Config}

# An attempt that runs: its unit of the pool, the budget that admit left, its target, and the channel of its outcome.
type Flight<-A: Data> is Type:
  Flight{ticket: Q.Ticket<A>, grant: Res.Grant, budget: Retry.Budget, target: String, chan: Chan(Retry.Outcome)}

def Out(-X: Type) -> Type:
  Result<&1, &1, U32 & String, X>

def Claimed(-A: Data) -> Type:
  Runner<A> & List<&1, Flight<A>> & Out(Unit)

def Ran(-A: Data) -> Type:
  Runner<A> & Out(Unit)

# Wall-clock ms since the Unix epoch. Deadlines must keep their meaning across a restart.
def clock() -> IO(Nat):
  do IO<Nat>:
    t : Time.Instant <- Time.now()
    return Time.Duration.to_ms_nat(Time.Instant.since_epoch(t))

def first(a: Out(Unit), b: Out(Unit)) -> Out(Unit):
  match a:
    case Fail{e}:
      Fail{e}
    case Done{u}:
      b

def commit.done(~A: Data, x: J.Journal & Out(Unit), s: State<A>, +op: Op<A>, p: Res.Pool, bs: Map<&2, Retry.Breaker>, c: Config) -> Ran(A):
  match x:
    case (j, Done{u}):
      (Runner{j, step(~A, s, op), p, bs, c}, Done{u})
    case (j, Fail{e}):
      (Runner{j, s, p, bs, c}, Fail{e})

# Appends op, and applies it once the append is durable. After a failed append the state is as it was,
# and the journal refuses every later append until the runner is reopened.
def commit(~A: Data, ~penc: A -> Bytes.Bytes, r: Runner<A>, +op: Op<A>) -> IO(Ran(A)):
  Runner{j, s, p, bs, c} = r
  do IO<Ran(A)>:
    x : J.Journal & Out(Unit) <- J.append(j, encode(~A, ~penc, op))
    return commit.done(~A, x, s, op, p, bs, c)

# A grant of this runner's pool always fits it, so Kept does not happen.
def release.got(-A: Data, x: Res.Release, j: J.Journal, s: State<A>, bs: Map<&2, Retry.Breaker>, c: Config) -> Runner<A>:
  match x:
    case Res.Released{p}:
      Runner{j, s, p, bs, c}
    case Res.Kept{p, g}:
      Runner{j, s, p, bs, c}

def release(-A: Data, r: Runner<A>, g: Res.Grant) -> Runner<A>:
  Runner{j, s, p, bs, c} = r
  release.got(A, Res.release(p, g), j, s, bs, c)

def claim.held(-A: Data, y: Ran(A), g: Res.Grant, fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  match y:
    case (r, Fail{e}):
      IO.pure(Claimed(A), (release(A, r, g), fs, Fail{e}))
    case (r, Done{u}):
      next(release(A, r, g), fs)

def claim.go(~A: Data, ~penc: A -> Bytes.Bytes, ~work: A -> IO(Retry.Outcome), +now: Nat, a: Retry.Breaker & Retry.Budget & Retry.Gate, +key: String,
    j: J.Journal, s: State<A>, p: Res.Pool, bs: Map<&2, Retry.Breaker>, c: Config, +id: Nat, d: Nat, +x: A, g: Res.Grant,
    fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  match a:
    case (+br, b, Retry.GateGo{}):
      do IO<Claimed(A)>:
        ch : Chan(Retry.Outcome) <- IO.fork(Retry.Outcome, work(x))
        next(Runner{j, s, p, Map.set(&2, Retry.Breaker, bs, key, br), c}, Con{Flight{Q.Ticket{id, d, x}, g, b, key, ch}, fs})
    case (+br, b, Retry.GateNo{why}):
      do IO<Claimed(A)>:
        y : Ran(A) <- commit(~A, ~penc, Runner{j, s, p, Map.set(&2, Retry.Breaker, bs, key, br), c}, held(A, why, br, id, now))
        claim.held(A, y, g, fs, next)

def claim.gate(~A: Data, ~penc: A -> Bytes.Bytes, ~work: A -> IO(Retry.Outcome), +now: Nat, got: Map<&2, Retry.Breaker> & Retry.Breaker, +key: String,
    j: J.Journal, +s: State<A>, p: Res.Pool, +c: Config, +id: Nat, d: Nat, +x: A, g: Res.Grant,
    fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  (bs, br) = got
  Config{pol, circ, idle} = c
  claim.go(~A, ~penc, ~work, now, Retry.admit(br, budget(pol, tries.get(tries(A, s), id)), now), key, j, s, p, bs, c, id, d, x, g, fs, next)

# The selected ticket asks its target's breaker and its own budget for an attempt.
def claim.admit(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), +now: Nat, r: Runner<A>, t: Q.Ticket<A>, g: Res.Grant,
    fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  Runner{j, s, p, bs, +c} = r
  Config{pol, circ, idle} = c
  Q.Ticket{id, d, +x} = t
  +key = target(x)
  claim.gate(~A, ~penc, ~work, now, Map.get(Retry.Breaker, Retry.Breaker.new(circ), bs, key), key, j, s, p, c, id, d, x, g, fs, next)

def claim.selected(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), +now: Nat, y: Ran(A),
    t: Q.Ticket<A>, g: Res.Grant, fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  match y:
    case (r, Fail{e}):
      IO.pure(Claimed(A), (release(A, r, g), fs, Fail{e}))
    case (r, Done{u}):
      claim.admit(~A, ~penc, ~target, ~work, now, r, t, g, fs, next)

def claim.pick(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), +now: Nat, k: Pick<A>, j: J.Journal, s: State<A>,
    bs: Map<&2, Retry.Breaker>, c: Config, fs: List<&1, Flight<A>>, next: Runner<A> -> List<&1, Flight<A>> -> IO(Claimed(A))) -> IO(Claimed(A)):
  match k:
    case Idle{p}:
      IO.pure(Claimed(A), (Runner{j, s, p, bs, c}, fs, Done{Unit{}}))
    case Picked{p, t, g}:
      do IO<Claimed(A)>:
        y : Ran(A) <- commit(~A, ~penc, Runner{j, s, p, bs, c}, Select{now})
        claim.selected(~A, ~penc, ~target, ~work, now, y, t, g, fs, next)

# Starts an attempt for each due ticket while the pool has a free unit. fuel bounds the tickets taken.
def claim(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), fuel: Nat, +now: Nat, r: Runner<A>, fs: List<&1, Flight<A>>) ->
    IO(Claimed(A)):
  match fuel:
    case 0n:
      IO.pure(Claimed(A), (r, fs, Done{Unit{}}))
    case 1n+n:
      Runner{j, +s, p, bs, c} = r
      claim.pick(~A, ~penc, ~target, ~work, now, pick(~A, p, s, now), j, s, bs, c, fs, (r2 => fs2 => claim(~A, ~penc, ~target, ~work, n, now, r2, fs2)))

def settle.done(-A: Data, y: Ran(A), g: Res.Grant, err: Out(Unit), next: Runner<A> -> Out(Unit) -> IO(Ran(A))) -> IO(Ran(A)):
  (r, res) = y
  next(release(A, r, g), first(err, res))

def settle.br(~A: Data, ~penc: A -> Bytes.Bytes, +failed: Bool, +key: String, +now: Nat, got: Map<&2, Retry.Breaker> & Retry.Breaker, +op: Op<A>,
    j: J.Journal, s: State<A>, p: Res.Pool, c: Config, g: Res.Grant, err: Out(Unit), next: Runner<A> -> Out(Unit) -> IO(Ran(A))) -> IO(Ran(A)):
  (bs, br) = got
  do IO<Ran(A)>:
    y : Ran(A) <- commit(~A, ~penc, Runner{j, s, p, Map.set(&2, Retry.Breaker, bs, key, Retry.Breaker.done(br, now, failed)), c}, op)
    settle.done(A, y, g, err, next)

def settle.op(~A: Data, ~penc: A -> Bytes.Bytes, +o: Retry.Outcome, b: Retry.Budget, +id: Nat, +key: String, +now: Nat, +rnd: Nat, r: Runner<A>, g: Res.Grant,
    err: Out(Unit), next: Runner<A> -> Out(Unit) -> IO(Ran(A))) -> IO(Ran(A)):
  Runner{j, +s, p, bs, +c} = r
  Config{pol, circ, idle} = c
  settle.br(~A, ~penc, Retry.failed(o), key, now, Map.get(Retry.Breaker, Retry.Breaker.new(circ), bs, key),
    after(A, o, pol, b, id, fails(tries.get(tries(A, s), id)), now, rnd), j, s, p, c, g, err, next)

def random(r: Out(U32)) -> Nat:
  match r:
    case Done{x}:
      U32.to_nat(x)
    case Fail{e}:
      0n

# Waits for the attempt, tells its target's breaker, appends Complete or Requeue, and returns its unit to the pool.
def settle.one(~A: Data, ~penc: A -> Bytes.Bytes, r: Runner<A>, f: Flight<A>, err: Out(Unit), next: Runner<A> -> Out(Unit) -> IO(Ran(A))) -> IO(Ran(A)):
  Flight{Q.Ticket{id, d, x}, g, b, key, ch} = f
  do IO<Ran(A)>:
    o : Retry.Outcome <- IO.join(Retry.Outcome, ch)
    now : Nat <- clock()
    rnd : Out(U32) <- IO.random_u32()
    settle.op(~A, ~penc, o, b, id, key, now, random(rnd), r, g, err, next)

def settle(~A: Data, ~penc: A -> Bytes.Bytes, fs: List<&1, Flight<A>>, r: Runner<A>, err: Out(Unit)) -> IO(Ran(A)):
  match fs:
    case Nil{}:
      IO.pure(Ran(A), (r, err))
    case Con{f, rest}:
      settle.one(~A, ~penc, r, f, err, (r2 => e2 => settle(~A, ~penc, rest, r2, e2)))

def empty.heap(-A: Data, h: H.Heap<Q.Ticket<A>>) -> Bool:
  match h:
    case H.HLeaf{}:
      True{}
    case H.HNode{n, t, l, r}:
      False{}

def empty.list(-A: Data, xs: List<&2, Q.Ticket<A>>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{t, rest}:
      False{}

# No ticket is pending or running.
def idle(-A: Data, s: State<A>) -> Bool:
  State{Q.State{n, h, run}, ts} = s
  Bool.and(empty.heap(A, h), empty.list(A, run))

def pending(-A: Data, s: State<A>) -> Nat:
  State{Q.State{n, h, run}, ts} = s
  H.Heap.size(Q.Ticket<A>, h)

def tick.ran(e: Out(Unit), b: Bool) -> Out(Bool):
  match e:
    case Fail{x}:
      Fail{x}
    case Done{u}:
      Done{b}

def tick.done(-A: Data, y: Ran(A)) -> Runner<A> & Out(Bool):
  (r, e) = y
  (r, tick.ran(e, True{}))

def tick.settle(~A: Data, ~penc: A -> Bytes.Bytes, c: Claimed(A)) -> IO(Runner<A> & Out(Bool)):
  match c:
    case (r, Nil{}, err):
      IO.pure(Runner<A> & Out(Bool), (r, tick.ran(err, False{})))
    case (r, Con{f, fs}, err):
      do IO<Runner<A> & Out(Bool)>:
        y : Ran(A) <- settle(~A, ~penc, Con{f, fs}, r, err)
        return tick.done(A, y)

def tick.at(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), +now: Nat, r: Runner<A>) -> IO(Runner<A> & Out(Bool)):
  Runner{j, +s, p, bs, c} = r
  do IO<Runner<A> & Out(Bool)>:
    k : Claimed(A) <- claim(~A, ~penc, ~target, ~work, 1n+pending(A, s), now, Runner{j, s, p, bs, c}, Nil{})
    tick.settle(~A, ~penc, k)

# One round: start an attempt for each due ticket the pool admits, wait for them all, and record each outcome.
# Done{True} when an attempt ran. work runs on its own; target names the breaker that guards it.
def tick(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), r: Runner<A>) -> IO(Runner<A> & Out(Bool)):
  do IO<Runner<A> & Out(Bool)>:
    now : Nat <- clock()
    tick.at(~A, ~penc, ~target, ~work, now, r)

def drain.ticked(-A: Data, +idle: U32, t: Runner<A> & Out(Bool), next: Runner<A> -> IO(Ran(A))) -> IO(Ran(A)):
  match t:
    case (r, Fail{e}):
      IO.pure(Ran(A), (r, Fail{e}))
    case (r, Done{True{}}):
      next(r)
    case (r, Done{False{}}):
      do IO<Ran(A)>:
        IO.sleep(idle)
        next(r)

def drain.if(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), done: Bool, r: Runner<A>, next: Runner<A> -> IO(Ran(A))) -> IO(Ran(A)):
  match done:
    case True{}:
      IO.pure(Ran(A), (r, Done{Unit{}}))
    case False{}:
      Runner{j, s, p, bs, +c} = r
      Config{pol, circ, +idle} = c
      do IO<Ran(A)>:
        t : Runner<A> & Out(Bool) <- tick(~A, ~penc, ~target, ~work, Runner{j, s, p, bs, c})
        drain.ticked(A, idle, t, next)

# Ticks until no ticket is pending or running. It waits idle ms after a round that started no attempt.
# Fails when fuel rounds leave work.
def drain(~A: Data, ~penc: A -> Bytes.Bytes, ~target: A -> String, ~work: A -> IO(Retry.Outcome), fuel: Nat, r: Runner<A>) -> IO(Ran(A)):
  match fuel:
    case 0n:
      Runner{j, +s, p, bs, c} = r
      IO.pure(Ran(A), (Runner{j, s, p, bs, c}, Bool.pick(Out(Unit), idle(A, s), Done{Unit{}}, Fail{(62, "runner: drain ran out of rounds")})))
    case 1n+n:
      Runner{j, +s, p, bs, c} = r
      drain.if(~A, ~penc, ~target, ~work, idle(A, s), Runner{j, s, p, bs, c}, (r2 => drain(~A, ~penc, ~target, ~work, n, r2)))

def orphans.next(-A: Data, y: Ran(A), err: Out(Unit), next: Runner<A> -> Out(Unit) -> IO(Ran(A))) -> IO(Ran(A)):
  (r, e) = y
  next(r, first(err, e))

# A running ticket at open lost its attempt in a crash: it is requeued at now, as a failed attempt.
def orphans(~A: Data, ~penc: A -> Bytes.Bytes, ts: List<&2, Q.Ticket<A>>, +now: Nat, r: Runner<A>, err: Out(Unit)) -> IO(Ran(A)):
  match ts:
    case Nil{}:
      IO.pure(Ran(A), (r, err))
    case Con{Q.Ticket{id, d, x}, rest}:
      do IO<Ran(A)>:
        y : Ran(A) <- commit(~A, ~penc, r, Requeue{id, now})
        orphans.next(A, y, err, (r2 => e2 => orphans(~A, ~penc, rest, now, r2, e2)))

def open.done(-A: Data, y: Ran(A)) -> IO(Out(Runner<A>)):
  match y:
    case (Runner{j, s, p, bs, c}, Fail{e}):
      do IO<Out(Runner<A>)>:
        J.close(j)
        return Fail{e}
    case (r, Done{u}):
      IO.pure(Out(Runner<A>), Done{r})

def open.got(~A: Data, ~penc: A -> Bytes.Bytes, x: Out(J.Journal & Maybe<&2, State<A>>), c: Config, +capacity: Nat) -> IO(Out(Runner<A>)):
  match x:
    case Fail{e}:
      IO.pure(Out(Runner<A>), Fail{e})
    case Done{(j, None{})}:
      do IO<Out(Runner<A>)>:
        J.close(j)
        return Fail{(22, "runner: a journal record is not a runner op")}
    case Done{(j, Some{+s})}:
      do IO<Out(Runner<A>)>:
        now : Nat <- clock()
        y : Ran(A) <- orphans(~A, ~penc, Q.running(A, queue(A, s)), now, Runner{j, s, Res.new(0n, capacity), Map.new(&2, Retry.Breaker), c}, Done{Unit{}})
        open.done(A, y)

def replay.step(~A: Data, ~pdec: Bytes.Bytes -> Maybe<&2, A>, acc: Maybe<&2, State<A>>, b: Bytes.Bytes) -> Maybe<&2, State<A>>:
  apply(~A, ~Bytes.Bytes, ~(y => decode(~A, ~pdec, y)), acc, b)

# Opens the runner at path: replays its journal into the state, then requeues each ticket that was running.
# capacity bounds the attempts that run at once. max caps a record's octets; limit caps the journal file.
# Fails when the journal fails to open, or a committed record is not an op.
def open(~A: Data, ~penc: A -> Bytes.Bytes, ~pdec: Bytes.Bytes -> Maybe<&2, A>, path: String, +max: U32, limit: U32, c: Config, +capacity: Nat) -> IO(Out(Runner<A>)):
  do IO<Out(Runner<A>)>:
    x : Out(J.Journal & Maybe<&2, State<A>>) <- J.open(~Maybe<&2, State<A>>, ~(acc => b => replay.step(~A, ~pdec, acc, b)), path, max, limit, Some{new(A)})
    open.got(~A, ~penc, x, c, capacity)

def enqueue.done(-A: Data, +id: Nat, y: Ran(A)) -> Runner<A> & Out(Nat):
  match y:
    case (r, Done{u}):
      (r, Done{id})
    case (r, Fail{e}):
      (r, Fail{e})

# Adds a job that is due at deadline (wall-clock ms) and answers its ticket id once the record is durable.
def enqueue(~A: Data, ~penc: A -> Bytes.Bytes, r: Runner<A>, +deadline: Nat, x: A) -> IO(Runner<A> & Out(Nat)):
  Runner{j, +s, p, bs, c} = r
  do IO<Runner<A> & Out(Nat)>:
    y : Ran(A) <- commit(~A, ~penc, Runner{j, s, p, bs, c}, Enqueue{deadline, x})
    return enqueue.done(A, Q.next_id(A, queue(A, s)), y)

# Cancels ticket id. A running attempt finishes, but its ticket is never selected again.
def cancel(~A: Data, ~penc: A -> Bytes.Bytes, r: Runner<A>, +id: Nat) -> IO(Ran(A)):
  commit(~A, ~penc, r, Cancel{id})

# The runner back, and a copy of its state.
def state(-A: Data, r: Runner<A>) -> Runner<A> & State<A>:
  Runner{j, +s, p, bs, c} = r
  (Runner{j, s, p, bs, c}, s)

def close(-A: Data, r: Runner<A>) -> IO(Unit):
  Runner{j, s, p, bs, c} = r
  J.close(j)
