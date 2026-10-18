import Base
import bend-mathlib@0.7.2.0/nat.bend as MNat
import bend-kit-scheduler@0.3.0.0/queue.bend as Q
import bend-kit-collections@0.1.3.0/heap.bend as H
import bend-kit-resources@0.1.0.0/resources.bend as Res
import bend-kit-retry@0.1.0.0/retry.bend as Retry
import ./runner.bend as R

# ---- replay

def encode.all(~A: Data, ~X: Type, ~enc: R.Op<A> -> X, ops: List<&2, R.Op<A>>) -> List<&1, X>:
  match ops:
    case Nil{}:
      Nil{}
    case Con{op, rest}:
      Con{enc(op), encode.all(~A, ~X, ~enc, rest)}

# The state after the live runner applies ops to s, one at a time.
def live(~A: Data, ops: List<&2, R.Op<A>>, s: R.State<A>) -> R.State<A>:
  match ops:
    case Nil{}:
      s
    case Con{op, rest}:
      live(~A, rest, R.step(~A, s, op))

# open's fold: each record into the replayed state, as J.replay folds the committed records.
def replay.from(~A: Data, ~X: Type, ~dec: X -> Maybe<&2, R.Op<A>>, xs: List<&1, X>, acc: Maybe<&2, R.State<A>>) -> Maybe<&2, R.State<A>>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      replay.from(~A, ~X, ~dec, rest, R.apply(~A, ~X, ~dec, acc, x))

# The state that open replays from the records of ops: the journal's committed records, in order.
def replayed(~A: Data, ~X: Type, ~enc: R.Op<A> -> X, ~dec: X -> Maybe<&2, R.Op<A>>, ops: List<&2, R.Op<A>>, s: R.State<A>) -> Maybe<&2, R.State<A>>:
  replay.from(~A, ~X, ~dec, encode.all(~A, ~X, ~enc, ops), Some{s})

# Replaying the records of any ops gives the state that applying them live gives, when every record decodes to its op.
law replay_live:
  for ~A: Data
  for ~X: Type
  for ~enc: R.Op<A> -> X
  for ~dec: X -> Maybe<&2, R.Op<A>>
  for ~round: @op: R.Op<A> -> {dec(enc(op)) == Some{op} : Maybe<&2, R.Op<A>>}
  for ops: List<&2, R.Op<A>>
  for s: R.State<A>
  {replayed(~A, ~X, ~enc, ~dec, ops, s) == Some{live(~A, ops, s)} : Maybe<&2, R.State<A>>}

# Recovery after a crash keeps the first k records of the journal. Replaying them gives the live state after those k ops.
law replay_prefix:
  for ~A: Data
  for ~X: Type
  for ~enc: R.Op<A> -> X
  for ~dec: X -> Maybe<&2, R.Op<A>>
  for ~round: @op: R.Op<A> -> {dec(enc(op)) == Some{op} : Maybe<&2, R.Op<A>>}
  for +ops: List<&2, R.Op<A>>
  for k: Nat
  for s: R.State<A>
  {replayed(~A, ~X, ~enc, ~dec, List.take(&2, R.Op<A>, ops, k), s) == Some{live(~A, List.take(&2, R.Op<A>, ops, k), s)} : Maybe<&2, R.State<A>>}

# ---- a finished ticket is never selected again

def selected(-A: Data, r: Q.State<A> & Maybe<&2, Q.Ticket<A>>) -> Maybe<&2, Q.Ticket<A>>:
  (q, t) = r
  t

# The ticket that a Select at now takes from s.
def next(~A: Data, now: Nat, s: R.State<A>) -> Maybe<&2, Q.Ticket<A>>:
  selected(A, Q.select(~A, now, R.queue(A, s)))

# Whether a ticket with id i is in heap h.
def has(-A: Data, h: H.Heap<Q.Ticket<A>>, +i: Nat) -> Bool:
  match h:
    case H.HLeaf{}:
      False{}
    case H.HNode{n, t, l, r}:
      Bool.or(Nat.is_eq(Q.id(A, t), i), Bool.or(has(A, l, i), has(A, r, i)))

# Ticket i was running in s when it completed: issued (below s's next id) and not pending.
# Complete then takes it from the running list, and any ops run after.
law complete_never_selected:
  for ~A: Data
  for +i: Nat
  for s: R.State<A>
  for fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s)))
  for idle: {has(A, Q.pending(A, R.queue(A, s)), i) == False{} : Bool}
  for ops: List<&2, R.Op<A>>
  for now: Nat
  for t: Q.Ticket<A>
  for e: {next(~A, now, live(~A, ops, R.step(~A, s, R.Complete{i}))) == Some{t} : Maybe<&2, Q.Ticket<A>>}
  {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}

# Cancel takes ticket i from both registries, so it needs no hypothesis but issue.
law cancel_never_selected:
  for ~A: Data
  for +i: Nat
  for s: R.State<A>
  for fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s)))
  for ops: List<&2, R.Op<A>>
  for now: Nat
  for t: Q.Ticket<A>
  for e: {next(~A, now, live(~A, ops, R.step(~A, s, R.Cancel{i}))) == Some{t} : Maybe<&2, Q.Ticket<A>>}
  {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}

# The same after a crash: the state that open replays from the journal never selects a completed ticket.
law recovered_never_selected:
  for ~A: Data
  for ~X: Type
  for ~enc: R.Op<A> -> X
  for ~dec: X -> Maybe<&2, R.Op<A>>
  for ~round: @op: R.Op<A> -> {dec(enc(op)) == Some{op} : Maybe<&2, R.Op<A>>}
  for +i: Nat
  for +s: R.State<A>
  for fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s)))
  for idle: {has(A, Q.pending(A, R.queue(A, s)), i) == False{} : Bool}
  for +ops: List<&2, R.Op<A>>
  for r: R.State<A>
  for back: {replayed(~A, ~X, ~enc, ~dec, ops, R.step(~A, s, R.Complete{i})) == Some{r} : Maybe<&2, R.State<A>>}
  for now: Nat
  for t: Q.Ticket<A>
  for e: {next(~A, now, r) == Some{t} : Maybe<&2, Q.Ticket<A>>}
  {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}

# ---- the pool bounds the attempts

def pick.pool(-A: Data, k: R.Pick<A>) -> Res.Pool:
  match k:
    case R.Picked{p, t, g}:
      p
    case R.Idle{p}:
      p

# The units held after a pick that started from h: one more for a Picked ticket, none for Idle.
def pick.held(-A: Data, k: R.Pick<A>, h: Nat) -> Nat:
  match k:
    case R.Picked{p, t, g}:
      Nat.add(h, 1n)
    case R.Idle{p}:
      h

def release.pool(r: Res.Release) -> Res.Pool:
  match r:
    case Res.Released{p}:
      p
    case Res.Kept{p, g}:
      p

# The pool after the picked ticket's grant goes back.
def pick.round(-A: Data, k: R.Pick<A>) -> Res.Pool:
  match k:
    case R.Picked{p, t, g}:
      release.pool(Res.release(p, g))
    case R.Idle{p}:
      p

# Each attempt holds exactly one unit of the pool.
law pick_holds_one:
  for ~A: Data
  for o: Nat
  for c: Nat
  for +h: Nat
  for +s: R.State<A>
  for +now: Nat
  {Res.reserved(pick.pool(A, R.pick(~A, Res.Pool{o, c, h}, s, now))) == pick.held(A, R.pick(~A, Res.Pool{o, c, h}, s, now), h) : Nat}

# The attempts that hold units never exceed the capacity.
law pick_bounded:
  for ~A: Data
  for o: Nat
  for c: Nat
  for h: Nat
  for e: MNat.le(h, c)
  for s: R.State<A>
  for now: Nat
  MNat.le(Res.reserved(pick.pool(A, R.pick(~A, Res.Pool{o, c, h}, s, now))), c)

# The grant of an attempt goes back once, and the pool is then as it was.
law pick_release:
  for ~A: Data
  for o: Nat
  for c: Nat
  for h: Nat
  for s: R.State<A>
  for now: Nat
  {pick.round(A, R.pick(~A, Res.Pool{o, c, h}, s, now)) == Res.Pool{o, c, h} : Res.Pool}

# ---- a failed attempt waits retry's wait

# A requeued ticket's deadline is now plus the wait that retry.plan gives.
law requeue_wait:
  for -A: Data
  for o: Retry.Outcome
  for p: Retry.Policy
  for b: Retry.Budget
  for +id: Nat
  for +n: Nat
  for +now: Nat
  for +r: Nat
  for w: Nat
  for e: {Retry.plan(o, p, b, n, now, r) == Retry.PlanWait{w} : Retry.Plan}
  {R.after(A, o, p, b, id, n, now, r) == R.Requeue{id, Nat.add(now, w)} : R.Op<A>}

# When retry.plan stops, the ticket completes.
law requeue_stop:
  for -A: Data
  for o: Retry.Outcome
  for p: Retry.Policy
  for b: Retry.Budget
  for +id: Nat
  for +n: Nat
  for +now: Nat
  for +r: Nat
  for e: {Retry.plan(o, p, b, n, now, r) == Retry.PlanStop{} : Retry.Plan}
  {R.after(A, o, p, b, id, n, now, r) == R.Complete{id} : R.Op<A>}
