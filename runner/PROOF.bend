import Base
import bend-mathlib@0.7.2.0/nat.bend as MNat
import bend-kit-scheduler@0.3.0.0/queue.bend as Q
import bend-kit-collections@0.1.3.0/heap.bend as H
import bend-kit-resources@0.1.0.0/resources.bend as Res
import bend-kit-retry@0.2.0.0/retry.bend as Retry
import ./runner.bend as R
import ./LAWS.bend as Laws

def split(-P: Bool -> Type, b: Bool, yes: {b == True{} : Bool} -> P(True{}), no: {b == False{} : Bool} -> P(False{})) -> P(b):
  match b:
    case True{}:
      yes({==})
    case False{}:
      no({==})

# ---- replay

def replay.go(~A: Data, ~X: Type, ~enc: R.Op<A> -> X, ~dec: X -> Maybe<&2, R.Op<A>>, ~round: @op: R.Op<A> -> {dec(enc(op)) == Some{op} : Maybe<&2, R.Op<A>>},
    ops: List<&2, R.Op<A>>, s: R.State<A>) -> {Laws.replayed(~A, ~X, ~enc, ~dec, ops, s) == Some{Laws.live(~A, ops, s)} : Maybe<&2, R.State<A>>}:
  match ops:
    case Nil{}:
      {==}
    case Con{+op, rest}:
      %Equal.sym(Maybe<&2, R.Op<A>>, dec(enc(op)), Some{op}, round(op)) : {Laws.replay.from(~A, ~X, ~dec, Laws.encode.all(~A, ~X, ~enc, rest), R.apply.op(~A, _, s)) == Some{Laws.live(~A, rest, R.step(~A, s, op))} : Maybe<&2, R.State<A>>}
      replay.go(~A, ~X, ~enc, ~dec, ~round, rest, R.step(~A, s, op))

def Laws.replay_live(A, X, enc, dec, round, ops, s):
  replay.go(~A, ~X, ~enc, ~dec, ~round, ops, s)

def Laws.replay_prefix(A, X, enc, dec, round, ops, k, s):
  replay.go(~A, ~X, ~enc, ~dec, ~round, List.take(&2, R.Op<A>, ops, k), s)

# ---- compaction

def restore.go(~A: Data, ~X: Type, ~enc: R.Rec<A> -> X, ~dec: X -> Maybe<&2, R.Rec<A>>, ~round: @r: R.Rec<A> -> {dec(enc(r)) == Some{r} : Maybe<&2, R.Rec<A>>},
    more: List<&2, R.Op<A>>, s: R.State<A>) -> {Laws.restore.from(~A, ~X, ~dec, Laws.encode.ops(~A, ~X, ~enc, more), Some{s}) == Some{Laws.live(~A, more, s)} : Maybe<&2, R.State<A>>}:
  match more:
    case Nil{}:
      {==}
    case Con{+op, rest}:
      %Equal.sym(Maybe<&2, R.Rec<A>>, dec(enc(R.Do{op})), Some{R.Do{op}}, round(R.Do{op})) : {Laws.restore.from(~A, ~X, ~dec, Laws.encode.ops(~A, ~X, ~enc, rest), R.load.rec(~A, _, s)) == Some{Laws.live(~A, rest, R.step(~A, s, op))} : Maybe<&2, R.State<A>>}
      restore.go(~A, ~X, ~enc, ~dec, ~round, rest, R.step(~A, s, op))

def Laws.replay_snapshot(A, X, enc, dec, round, ops, s, more, t):
  %Equal.sym(Maybe<&2, R.Rec<A>>, dec(enc(R.Snap{Laws.live(~A, ops, s)})), Some{R.Snap{Laws.live(~A, ops, s)}}, round(R.Snap{Laws.live(~A, ops, s)})) : {Laws.restore.from(~A, ~X, ~dec, Laws.encode.ops(~A, ~X, ~enc, more), R.load.rec(~A, _, t)) == Some{Laws.live(~A, more, Laws.live(~A, ops, s))} : Maybe<&2, R.State<A>>}
  restore.go(~A, ~X, ~enc, ~dec, ~round, more, Laws.live(~A, ops, s))

# ---- retry

def Laws.requeue_wait(A, o, p, b, id, n, now, r, w, e):
  %Equal.sym(Retry.Plan, Retry.plan(o, p, b, n, now, r), Retry.PlanWait{w}, e) : {R.after.plan(A, _, o, b, id, now) == R.Requeue{id, Nat.add(now, w)} : R.Op<A>}
  {==}

def Laws.settled_complete(A, p, b, id, n, now, r):
  {==}

def Laws.unsafe_abandon(A, p, b, id, n, now, r):
  {==}

def Laws.failed_abandon(A, p, b, id, n, now, r):
  {==}

def Laws.transient_abandon(A, a, p, b, id, n, now, r, e):
  %Equal.sym(Retry.Plan, Retry.plan(Retry.Transient{a}, p, b, n, now, r), Retry.PlanStop{}, e) : {R.after.plan(A, _, Retry.Transient{a}, b, id, now) == R.Abandon{id, R.gave(b)} : R.Op<A>}
  {==}

# ---- pool

# Every pick is Idle with the pool unchanged, or the reserve of one unit for a selected ticket.
def pick_cases(~A: Data, -P: R.Pick<A> -> Type, +p: Res.Pool, s: R.State<A>, +now: Nat, idle: P(R.Idle{p}),
    took: @t: Q.Ticket<A> -> P(R.pick.took(A, Res.reserve(p, 1n), t))) -> P(R.pick(~A, p, s, now)):
  match s:
    case R.State{Q.State{i, H.HLeaf{}, r}, ts, ds, bs}:
      idle
    case R.State{Q.State{i, H.HNode{n, +t, l, q}, r}, ts, ds, bs}:
      split(b => P(R.pick.sel(A, Q.select.due(~A, b, i, H.HNode{n, t, l, q}, r, t, l, q), p)), Nat.is_le(Q.deadline(A, t), now),
        e => took(t),
        e => idle)

def took.holds(-A: Data, +o: Nat, +c: Nat, +h: Nat, +t: Q.Ticket<A>) ->
    {Res.reserved(Laws.pick.pool(A, R.pick.took(A, Res.reserve(Res.Pool{o, c, h}, 1n), t))) == Laws.pick.held(A, R.pick.took(A, Res.reserve(Res.Pool{o, c, h}, 1n), t), h) : Nat}:
  split(b => {Res.reserved(Laws.pick.pool(A, R.pick.took(A, Res.reserve.go(b, o, c, h, 1n), t))) == Laws.pick.held(A, R.pick.took(A, Res.reserve.go(b, o, c, h, 1n), t), h) : Nat},
    Nat.is_le(Nat.add(h, 1n), c),
    e => {==},
    e => {==})

def Laws.pick_holds_one(A, o, c, h, s, now):
  +o = o
  +c = c
  pick_cases(~A, k => {Res.reserved(Laws.pick.pool(A, k)) == Laws.pick.held(A, k, h) : Nat}, Res.Pool{o, c, h}, s, now, {==}, t => took.holds(A, o, c, h, t))

def took.bounded(-A: Data, +o: Nat, +c: Nat, +h: Nat, e: MNat.le(h, c), +t: Q.Ticket<A>) ->
    MNat.le(Res.reserved(Laws.pick.pool(A, R.pick.took(A, Res.reserve(Res.Pool{o, c, h}, 1n), t))), c):
  split(b => MNat.le(Res.reserved(Laws.pick.pool(A, R.pick.took(A, Res.reserve.go(b, o, c, h, 1n), t))), c),
    Nat.is_le(Nat.add(h, 1n), c),
    f => f,
    f => e)

def Laws.pick_bounded(A, o, c, h, e, s, now):
  +o = o
  +c = c
  +h = h
  +now = now
  +e = e
  pick_cases(~A, k => MNat.le(Res.reserved(Laws.pick.pool(A, k)), c), Res.Pool{o, c, h}, s, now, e, t => took.bounded(A, o, c, h, e, t))

def zero_le(h: Nat) -> {Nat.is_le(0n, h) == True{} : Bool}:
  match h:
    case 0n:
      {==}
    case 1n+p:
      {==}

def took.release.go(+o: Nat, +c: Nat, +h: Nat) -> {Laws.release.pool(Res.release(Res.Pool{o, c, Nat.add(h, 1n)}, Res.Grant{o, 1n})) == Res.Pool{o, c, h} : Res.Pool}:
  %MNat.add_comm(1n, h) : {Laws.release.pool(Res.release(Res.Pool{o, c, _}, Res.Grant{o, 1n})) == Res.Pool{o, c, h} : Res.Pool}
  %Equal.sym(Bool, Nat.is_eq(o, o), True{}, MNat.is_eq_refl(o)) : {Laws.release.pool(Res.release.go(Bool.and(_, Nat.is_le(1n, 1n+h)), o, c, 1n+h, o, 1n)) == Res.Pool{o, c, h} : Res.Pool}
  %Equal.sym(Bool, Nat.is_le(0n, h), True{}, zero_le(h)) : {Laws.release.pool(Res.release.go(_, o, c, 1n+h, o, 1n)) == Res.Pool{o, c, h} : Res.Pool}
  %Equal.sym(Nat, Nat.sub(h, 0n), h, MNat.sub_zero(h)) : {Res.Pool{o, c, _} == Res.Pool{o, c, h} : Res.Pool}
  {==}

def took.release(-A: Data, +o: Nat, +c: Nat, +h: Nat, +t: Q.Ticket<A>) ->
    {Laws.pick.round(A, R.pick.took(A, Res.reserve(Res.Pool{o, c, h}, 1n), t)) == Res.Pool{o, c, h} : Res.Pool}:
  split(b => {Laws.pick.round(A, R.pick.took(A, Res.reserve.go(b, o, c, h, 1n), t)) == Res.Pool{o, c, h} : Res.Pool},
    Nat.is_le(Nat.add(h, 1n), c),
    f => took.release.go(o, c, h),
    f => {==})

def Laws.pick_release(A, o, c, h, s, now):
  +o = o
  +c = c
  +h = h
  +now = now
  pick_cases(~A, k => {Laws.pick.round(A, k) == Res.Pool{o, c, h} : Res.Pool}, Res.Pool{o, c, h}, s, now, {==}, t => took.release(A, o, c, h, t))

# ---- a finished ticket is never selected again

# The queue lemmas below follow scheduler's queue_proof.bend, restated over the hub queue that runner imports.

# Evidence pairs are Data, so a proof may use them more than once.
type Both<-A: Data, -B: Data> is Data:
  Both{left: A, right: B}

def all.heap(-A: Data, -P: Q.Ticket<A> -> Data, h: H.Heap<Q.Ticket<A>>) -> Data:
  match h:
    case H.HLeaf{}:
      Unit
    case H.HNode{n, t, l, r}:
      Both<P(t), Both<all.heap(A, P, l), all.heap(A, P, r)>>

def absent.ticket(-A: Data, i: Nat, t: Q.Ticket<A>) -> Data:
  {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}

def absent.heap(-A: Data, h: H.Heap<Q.Ticket<A>>, +i: Nat) -> Data:
  all.heap(A, absent.ticket(A, i), h)

def absent.list(-A: Data, xs: List<&2, Q.Ticket<A>>, +i: Nat) -> Data:
  match xs:
    case Nil{}:
      Unit
    case Con{t, rest}:
      Both<{Nat.is_eq(Q.id(A, t), i) == False{} : Bool}, absent.list(A, rest, i)>

def absent.dead(-A: Data, +i: Nat, ds: List<&2, R.Dead<A>>) -> Data:
  match ds:
    case Nil{}:
      Unit
    case Con{d, rest}:
      Both<{Nat.is_eq(R.dead.id(A, d), i) == False{} : Bool}, absent.dead(A, i, rest)>

def anything(-A: Data, ds: List<&2, R.Dead<A>>) -> Data:
  Unit

# s will issue no id i again, ticket i is neither pending nor running, and P holds of the dead tickets.
def inv(-A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, s: R.State<A>) -> Data:
  match s:
    case R.State{Q.State{n, h, r}, ts, ds, bs}:
      Both<MNat.lt(i, n), Both<absent.heap(A, h, i), Both<absent.list(A, r, i), P(ds)>>>

# Ticket i is in no registry of s, and s will issue no id i again.
def gone(-A: Data, +i: Nat, s: R.State<A>) -> Data:
  inv(A, i, absent.dead(A, i), s)

def lt_ne(i: Nat, n: Nat, e: MNat.lt(i, n)) -> {Nat.is_eq(n, i) == False{} : Bool}:
  match i n:
    case 0n 0n:
      Empty.absurd({Nat.is_eq(0n, 0n) == False{} : Bool}, MNat.lt_irrefl(0n, e))
    case 0n 1n+m:
      {==}
    case 1n+p 0n:
      {==}
    case 1n+p 1n+m:
      lt_ne(p, m, e)

def merge_all(~A: Data, -P: Q.Ticket<A> -> Data, +fuel: Nat, +a: H.Heap<Q.Ticket<A>>, +b: H.Heap<Q.Ticket<A>>, +ea: all.heap(A, P, a), +eb: all.heap(A, P, b)) -> all.heap(A, P, H.Heap.merge.go(~Q.Ticket<A>, ~(x => y => Q.le(A, x, y)), fuel, a, b)):
  match fuel:
    case 0n:
      ea
    case 1n+f:
      match a b:
        case H.HLeaf{} H.HLeaf{}:
          Unit{}
        case H.HLeaf{} H.HNode{nb, y, bl, br}:
          eb
        case H.HNode{na, x, al, ar} H.HLeaf{}:
          ea
        case H.HNode{na, x, al, ar} H.HNode{nb, y, bl, br}:
          Both{ex, Both{eal, ear}} = ea
          Both{ey, Both{ebl, ebr}} = eb
          split(c => all.heap(A, P, H.HNode{Nat.add(na, nb), Bool.pick(Q.Ticket<A>, c, x, y), H.Heap.merge.go(~Q.Ticket<A>, ~(x => y => Q.le(A, x, y)), f, Bool.pick(H.Heap<Q.Ticket<A>>, c, ar, br), Bool.pick(H.Heap<Q.Ticket<A>>, c, H.HNode{nb, y, bl, br}, H.HNode{na, x, al, ar})), Bool.pick(H.Heap<Q.Ticket<A>>, c, al, bl)}), Q.le(A, x, y),
            e => Both{ex, Both{merge_all(~A, P, f, ar, H.HNode{nb, y, bl, br}, ear, Both{ey, Both{ebl, ebr}}), eal}},
            e => Both{ey, Both{merge_all(~A, P, f, br, H.HNode{na, x, al, ar}, ebr, Both{ex, Both{eal, ear}}), ebl}})

def merge_all.full(~A: Data, -P: Q.Ticket<A> -> Data, +a: H.Heap<Q.Ticket<A>>, +b: H.Heap<Q.Ticket<A>>, ea: all.heap(A, P, a), eb: all.heap(A, P, b)) -> all.heap(A, P, H.Heap.merge(~Q.Ticket<A>, ~(x => y => Q.le(A, x, y)), a, b)):
  merge_all(~A, P, Nat.add(H.Heap.size(Q.Ticket<A>, a), H.Heap.size(Q.Ticket<A>, b)), a, b, ea, eb)

def remove_all(~A: Data, -P: Q.Ticket<A> -> Data, +h: H.Heap<Q.Ticket<A>>, +i: Nat, +eh: all.heap(A, P, h)) -> all.heap(A, P, Q.remove.heap(~A, h, i)):
  match h:
    case H.HLeaf{}:
      Unit{}
    case H.HNode{n, t, l, r}:
      Both{et, Both{el, er}} = eh
      +l2 = Q.remove.heap(~A, l, i)
      +r2 = Q.remove.heap(~A, r, i)
      +el2 = remove_all(~A, P, l, i, el)
      +er2 = remove_all(~A, P, r, i, er)
      split(c => all.heap(A, P, Q.remove.heap.keep(~A, c, t, l2, r2)), Nat.is_eq(Q.id(A, t), i),
        e => merge_all.full(~A, P, l2, r2, el2, er2),
        e => Both{et, Both{el2, er2}})

def remove_absent.heap(~A: Data, +h: H.Heap<Q.Ticket<A>>, +i: Nat) -> absent.heap(A, Q.remove.heap(~A, h, i), i):
  match h:
    case H.HLeaf{}:
      Unit{}
    case H.HNode{n, t, l, r}:
      +l2 = Q.remove.heap(~A, l, i)
      +r2 = Q.remove.heap(~A, r, i)
      +el = remove_absent.heap(~A, l, i)
      +er = remove_absent.heap(~A, r, i)
      split(c => absent.heap(A, Q.remove.heap.keep(~A, c, t, l2, r2), i), Nat.is_eq(Q.id(A, t), i),
        e => merge_all.full(~A, absent.ticket(A, i), l2, r2, el, er),
        e => Both{e, Both{el, er}})

def remove_absent.list(-A: Data, +xs: List<&2, Q.Ticket<A>>, +i: Nat) -> absent.list(A, Q.remove.list(A, xs, i), i):
  match xs:
    case Nil{}:
      Unit{}
    case Con{t, rest}:
      +r2 = Q.remove.list(A, rest, i)
      +er = remove_absent.list(A, rest, i)
      split(c => absent.list(A, Q.remove.list.keep(A, c, t, r2), i), Nat.is_eq(Q.id(A, t), i),
        e => er,
        e => Both{e, er})

# Removing ticket j keeps ticket i absent.
def remove_keeps.list(-A: Data, +xs: List<&2, Q.Ticket<A>>, +j: Nat, +i: Nat, +e: absent.list(A, xs, i)) -> absent.list(A, Q.remove.list(A, xs, j), i):
  match xs:
    case Nil{}:
      Unit{}
    case Con{t, rest}:
      Both{et, er} = e
      +r2 = Q.remove.list(A, rest, j)
      +er2 = remove_keeps.list(A, rest, j, i, er)
      split(c => absent.list(A, Q.remove.list.keep(A, c, t, r2), i), Nat.is_eq(Q.id(A, t), j),
        f => er2,
        f => Both{et, er2})

def found.absent(-A: Data, m: Maybe<&2, Q.Ticket<A>>, +i: Nat) -> Data:
  match m:
    case None{}:
      Unit
    case Some{t}:
      absent.ticket(A, i, t)

def taken.ok(-A: Data, tk: Q.Taken<A>, +i: Nat) -> Data:
  match tk:
    case Q.Taken{rest, found}:
      Both<absent.list(A, rest, i), found.absent(A, found, i)>

def keep_ok(-A: Data, b: Bool, t: Q.Ticket<A>, tk: Q.Taken<A>, +i: Nat, +et: absent.ticket(A, i, t), etk: taken.ok(A, tk, i)) -> taken.ok(A, Q.take.keep(A, b, t, tk), i):
  match b tk:
    case True{} Q.Taken{rest, found}:
      Both{erest, ef} = etk
      Both{erest, et}
    case False{} Q.Taken{rest, found}:
      Both{erest, ef} = etk
      Both{Both{et, erest}, ef}

# Taking ticket j from a list without ticket i leaves no i, and takes no i.
def take_ok(-A: Data, +xs: List<&2, Q.Ticket<A>>, +j: Nat, +i: Nat, e: absent.list(A, xs, i)) -> taken.ok(A, Q.take.list(A, xs, j), i):
  match xs:
    case Nil{}:
      Both{Unit{}, Unit{}}
    case Con{t, rest}:
      Both{et, er} = e
      keep_ok(A, Nat.is_eq(Q.id(A, t), j), t, Q.take.list(A, rest, j), i, et, take_ok(A, rest, j, i, er))

def taken.rem_ok(-A: Data, tk: Q.Taken<A>, +i: Nat) -> Data:
  match tk:
    case Q.Taken{rest, found}:
      absent.list(A, rest, i)

def ok_rem(-A: Data, tk: Q.Taken<A>, +i: Nat, etk: taken.ok(A, tk, i)) -> taken.rem_ok(A, tk, i):
  match tk:
    case Q.Taken{rest, found}:
      Both{erest, ef} = etk
      erest

def keep_absent(-A: Data, b: Bool, t: Q.Ticket<A>, tk: Q.Taken<A>, +i: Nat, et: {b == False{} : Bool} -> absent.ticket(A, i, t), erest: taken.rem_ok(A, tk, i)) ->
    taken.rem_ok(A, Q.take.keep(A, b, t, tk), i):
  match b tk:
    case True{} Q.Taken{rest, found}:
      erest
    case False{} Q.Taken{rest, found}:
      Both{et({==}), erest}

# Taking ticket i leaves no i in the list.
def take_absent(-A: Data, +xs: List<&2, Q.Ticket<A>>, +i: Nat) -> taken.rem_ok(A, Q.take.list(A, xs, i), i):
  match xs:
    case Nil{}:
      Unit{}
    case Con{t, rest}:
      keep_absent(A, Nat.is_eq(Q.id(A, t), i), t, Q.take.list(A, rest, i), i, f => f, take_absent(A, rest, i))

def complete_inv(~A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, tk: Q.Taken<A>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, ts: R.Tries(), ds: List<&2, R.Dead<A>>, bs: R.Breakers(),
    lt: MNat.lt(i, n), eh: absent.heap(A, h, i), erem: taken.rem_ok(A, tk, i), ed: P(ds)) ->
    inv(A, i, P, R.step.completed(A, Q.complete.taken(A, tk, n, h), ts, ds, bs)):
  match tk:
    case Q.Taken{rest, found}:
      Both{lt, Both{eh, Both{erem, ed}}}

def found.of(-A: Data, tk: Q.Taken<A>) -> Maybe<&2, Q.Ticket<A>>:
  match tk:
    case Q.Taken{rest, found}:
      found

def abandon_inv(~A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, tk: Q.Taken<A>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, ts: R.Tries(), ds: List<&2, R.Dead<A>>, bs: R.Breakers(), w: R.Why,
    lt: MNat.lt(i, n), eh: absent.heap(A, h, i), erem: taken.rem_ok(A, tk, i), ed: P(R.dead.bury(A, found.of(A, tk), ds, w))) ->
    inv(A, i, P, R.step.abandoned(A, Q.complete.taken(A, tk, n, h), ts, ds, bs, w)):
  match tk:
    case Q.Taken{rest, found}:
      Both{lt, Both{eh, Both{erem, ed}}}

def requeue_inv(~A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, tk: Q.Taken<A>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, +d: Nat, ts: R.Tries(), ds: List<&2, R.Dead<A>>, bs: R.Breakers(),
    lt: MNat.lt(i, n), eh: absent.heap(A, h, i), etk: taken.ok(A, tk, i), ed: P(ds)) ->
    inv(A, i, P, R.step.requeued(A, Q.requeue.completed(~A, Q.complete.taken(A, tk, n, h), d), ts, ds, bs)):
  match tk:
    case Q.Taken{rest, None{}}:
      Both{erest, ef} = etk
      Both{lt, Both{eh, Both{erest, ed}}}
    case Q.Taken{rest, Some{Q.Ticket{j, old, x}}}:
      Both{erest, ej} = etk
      Both{lt, Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{j, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{ej, Both{Unit{}, Unit{}}}, eh), Both{erest, ed}}}

def select_inv(~A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, +now: Nat, +n: Nat, h: H.Heap<Q.Ticket<A>>, r: List<&2, Q.Ticket<A>>, ts: R.Tries(), ds: List<&2, R.Dead<A>>, bs: R.Breakers(),
    +lt: MNat.lt(i, n), +eh: absent.heap(A, h, i), +er: absent.list(A, r, i), +ed: P(ds)) ->
    inv(A, i, P, R.step.selected(A, Q.select(~A, now, Q.State{n, h, r}), ts, ds, bs)):
  match h:
    case H.HLeaf{}:
      Both{lt, Both{eh, Both{er, ed}}}
    case H.HNode{size, +t, +l, +q}:
      Both{+et, Both{+el, +eq}} = eh
      split(c => inv(A, i, P, R.step.selected(A, Q.select.due(~A, c, n, H.HNode{size, t, l, q}, r, t, l, q), ts, ds, bs)), Nat.is_le(Q.deadline(A, t), now),
        e => Both{lt, Both{merge_all.full(~A, absent.ticket(A, i), l, q, el, eq), Both{Both{et, er}, ed}}},
        e => Both{lt, Both{Both{et, Both{el, eq}}, Both{er, ed}}})

def revive_inv(~A: Data, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, m: Maybe<&2, Q.Ticket<A>>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, r: List<&2, Q.Ticket<A>>, ts: R.Tries(),
    rest: List<&2, R.Dead<A>>, bs: R.Breakers(), +d: Nat, lt: MNat.lt(i, n), eh: absent.heap(A, h, i), er: absent.list(A, r, i), em: found.absent(A, m, i), ed: P(rest)) ->
    inv(A, i, P, R.step.revived(~A, m, n, h, r, ts, rest, bs, d)):
  match m:
    case None{}:
      Both{lt, Both{eh, Both{er, ed}}}
    case Some{Q.Ticket{k, old, x}}:
      Both{lt, Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{k, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{em, Both{Unit{}, Unit{}}}, eh), Both{er, ed}}}

# ---- dead tickets

def remove_keeps.dead(-A: Data, +ds: List<&2, R.Dead<A>>, +j: Nat, +i: Nat, +e: absent.dead(A, i, ds)) -> absent.dead(A, i, R.dead.remove(A, ds, j)):
  match ds:
    case Nil{}:
      Unit{}
    case Con{d, rest}:
      Both{ed, er} = e
      +r2 = R.dead.remove(A, rest, j)
      +er2 = remove_keeps.dead(A, rest, j, i, er)
      split(c => absent.dead(A, i, R.dead.remove.keep(A, c, d, r2)), Nat.is_eq(R.dead.id(A, d), j),
        f => er2,
        f => Both{ed, er2})

def remove_absent.dead(-A: Data, +ds: List<&2, R.Dead<A>>, +i: Nat) -> absent.dead(A, i, R.dead.remove(A, ds, i)):
  match ds:
    case Nil{}:
      Unit{}
    case Con{d, rest}:
      +r2 = R.dead.remove(A, rest, i)
      +er = remove_absent.dead(A, rest, i)
      split(c => absent.dead(A, i, R.dead.remove.keep(A, c, d, r2)), Nat.is_eq(R.dead.id(A, d), i),
        e => er,
        e => Both{e, er})

def find_choose_absent(-A: Data, b: Bool, d: R.Dead<A>, m: Maybe<&2, Q.Ticket<A>>, +i: Nat, e: {Nat.is_eq(R.dead.id(A, d), i) == False{} : Bool}, em: found.absent(A, m, i)) ->
    found.absent(A, R.dead.find.choose(A, b, d, m), i):
  match b d:
    case True{} R.Dead{t, w}:
      e
    case False{} x:
      em

# A dead list without ticket i finds no ticket i.
def find_absent(-A: Data, +ds: List<&2, R.Dead<A>>, +j: Nat, +i: Nat, e: absent.dead(A, i, ds)) -> found.absent(A, R.dead.find(A, ds, j), i):
  match ds:
    case Nil{}:
      Unit{}
    case Con{d, rest}:
      Both{ed, er} = e
      find_choose_absent(A, Nat.is_eq(R.dead.id(A, d), j), d, R.dead.find(A, rest, j), i, ed, find_absent(A, rest, j, i, er))

def eq_ne(a: Nat, j: Nat, i: Nat, e1: {Nat.is_eq(a, j) == True{} : Bool}, e2: {Nat.is_eq(j, i) == False{} : Bool}) -> {Nat.is_eq(a, i) == False{} : Bool}:
  match a j i:
    case 0n 0n 0n:
      e2
    case 0n 0n 1n+k:
      {==}
    case 0n 1n+m c:
      Empty.absurd({Nat.is_eq(0n, c) == False{} : Bool}, MNat.internal_false_ne_true(e1))
    case 1n+p 0n c:
      Empty.absurd({Nat.is_eq(1n+p, c) == False{} : Bool}, MNat.internal_false_ne_true(e1))
    case 1n+p 1n+m 0n:
      {==}
    case 1n+p 1n+m 1n+k:
      eq_ne(p, m, k, e1, e2)

# Finding ticket j, when j is not i, finds no ticket i.
def find_other(-A: Data, +ds: List<&2, R.Dead<A>>, +j: Nat, +i: Nat, +ne: {Nat.is_eq(j, i) == False{} : Bool}) -> found.absent(A, R.dead.find(A, ds, j), i):
  match ds:
    case Nil{}:
      Unit{}
    case Con{R.Dead{Q.Ticket{+k, dd, x}, w}, rest}:
      +em = find_other(A, rest, j, i, ne)
      split(c => found.absent(A, R.dead.find.choose(A, c, R.Dead{Q.Ticket{k, dd, x}, w}, R.dead.find(A, rest, j)), i), Nat.is_eq(k, j),
        f => eq_ne(k, j, i, f, ne),
        f => em)

def bury_found(-A: Data, m: Maybe<&2, Q.Ticket<A>>, ds: List<&2, R.Dead<A>>, w: R.Why, +i: Nat, ef: found.absent(A, m, i), ed: absent.dead(A, i, ds)) ->
    absent.dead(A, i, R.dead.bury(A, m, ds, w)):
  match m:
    case None{}:
      ed
    case Some{t}:
      Both{ef, ed}

def bury_absent(-A: Data, tk: Q.Taken<A>, ds: List<&2, R.Dead<A>>, w: R.Why, +i: Nat, etk: taken.ok(A, tk, i), ed: absent.dead(A, i, ds)) ->
    absent.dead(A, i, R.dead.bury(A, found.of(A, tk), ds, w)):
  match tk:
    case Q.Taken{rest, found}:
      Both{erest, ef} = etk
      bury_found(A, found, ds, w, i, ef, ed)

# ---- every op keeps a gone ticket gone

def step_gone(~A: Data, +i: Nat, s: R.State<A>, op: R.Op<A>, g: gone(A, i, s)) -> gone(A, i, R.step(~A, s, op)):
  match s op:
    case R.State{Q.State{+n, h, r}, ts, ds, bs} R.Enqueue{d, x}:
      Both{+lt, Both{eh, Both{er, ed}}} = g
      Both{MNat.lt_trans(i, n, 1n+n, lt, MNat.lt_succ_self(n)), Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{n, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{lt_ne(i, n, lt), Both{Unit{}, Unit{}}}, eh), Both{er, ed}}}
    case R.State{Q.State{n, h, r}, ts, ds, bs} R.Select{now}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      select_inv(~A, i, absent.dead(A, i), now, n, h, r, ts, ds, bs, lt, eh, er, ed)
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Complete{+j}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      complete_inv(~A, i, absent.dead(A, i), Q.take.list(A, r, j), n, h, R.tries.drop(ts, j), ds, bs, lt, eh, ok_rem(A, Q.take.list(A, r, j), i, take_ok(A, r, j, i, er)), ed)
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Cancel{+j}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      Both{lt, Both{remove_all(~A, absent.ticket(A, i), h, j, eh), Both{remove_keeps.list(A, r, j, i, er), remove_keeps.dead(A, ds, j, i, ed)}}}
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Requeue{+j, d}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      requeue_inv(~A, i, absent.dead(A, i), Q.take.list(A, r, j), n, h, d, R.tries.bump(ts, j), ds, bs, lt, eh, take_ok(A, r, j, i, er), ed)
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Defer{+j, d}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      requeue_inv(~A, i, absent.dead(A, i), Q.take.list(A, r, j), n, h, d, ts, ds, bs, lt, eh, take_ok(A, r, j, i, er), ed)
    case R.State{Q.State{n, h, +r}, ts, +ds, bs} R.Abandon{+j, +w}:
      Both{lt, Both{eh, Both{+er, ed}}} = g
      abandon_inv(~A, i, absent.dead(A, i), Q.take.list(A, r, j), n, h, R.tries.drop(ts, j), ds, bs, w, lt, eh, ok_rem(A, Q.take.list(A, r, j), i, take_ok(A, r, j, i, er)),
        bury_absent(A, Q.take.list(A, r, j), ds, w, i, take_ok(A, r, j, i, er), ed))
    case R.State{Q.State{n, h, r}, ts, +ds, bs} R.Revive{+j, d}:
      Both{lt, Both{eh, Both{er, +ed}}} = g
      revive_inv(~A, i, absent.dead(A, i), R.dead.find(A, ds, j), n, h, r, ts, R.dead.remove(A, ds, j), bs, d, lt, eh, er, find_absent(A, ds, j, i, ed), remove_keeps.dead(A, ds, j, i, ed))
    case R.State{Q.State{n, h, r}, ts, ds, bs} R.Break{k, b}:
      g

def live_gone(~A: Data, +i: Nat, ops: List<&2, R.Op<A>>, +s: R.State<A>, g: gone(A, i, s)) -> gone(A, i, Laws.live(~A, ops, s)):
  match ops:
    case Nil{}:
      g
    case Con{op, rest}:
      +op = op
      live_gone(~A, i, rest, R.step(~A, s, op), step_gone(~A, i, s, op, g))

# Every op but a Revive of i keeps ticket i out of the queue, whether or not it is dead.
def step_buried(~A: Data, +i: Nat, s: R.State<A>, op: R.Op<A>, g: inv(A, i, anything(A), s), no: {Laws.revived(A, op, i) == False{} : Bool}) ->
    inv(A, i, anything(A), R.step(~A, s, op)):
  match s op:
    case R.State{Q.State{+n, h, r}, ts, ds, bs} R.Enqueue{d, x}:
      Both{+lt, Both{eh, Both{er, ed}}} = g
      Both{MNat.lt_trans(i, n, 1n+n, lt, MNat.lt_succ_self(n)), Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{n, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{lt_ne(i, n, lt), Both{Unit{}, Unit{}}}, eh), Both{er, Unit{}}}}
    case R.State{Q.State{n, h, r}, ts, ds, bs} R.Select{now}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      select_inv(~A, i, anything(A), now, n, h, r, ts, ds, bs, lt, eh, er, Unit{})
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Complete{+j}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      complete_inv(~A, i, anything(A), Q.take.list(A, r, j), n, h, R.tries.drop(ts, j), ds, bs, lt, eh, ok_rem(A, Q.take.list(A, r, j), i, take_ok(A, r, j, i, er)), Unit{})
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Cancel{+j}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      Both{lt, Both{remove_all(~A, absent.ticket(A, i), h, j, eh), Both{remove_keeps.list(A, r, j, i, er), Unit{}}}}
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Requeue{+j, d}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      requeue_inv(~A, i, anything(A), Q.take.list(A, r, j), n, h, d, R.tries.bump(ts, j), ds, bs, lt, eh, take_ok(A, r, j, i, er), Unit{})
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Defer{+j, d}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      requeue_inv(~A, i, anything(A), Q.take.list(A, r, j), n, h, d, ts, ds, bs, lt, eh, take_ok(A, r, j, i, er), Unit{})
    case R.State{Q.State{n, h, +r}, ts, ds, bs} R.Abandon{+j, w}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      abandon_inv(~A, i, anything(A), Q.take.list(A, r, j), n, h, R.tries.drop(ts, j), ds, bs, w, lt, eh, ok_rem(A, Q.take.list(A, r, j), i, take_ok(A, r, j, i, er)), Unit{})
    case R.State{Q.State{n, h, r}, ts, +ds, bs} R.Revive{+j, d}:
      Both{lt, Both{eh, Both{er, ed}}} = g
      revive_inv(~A, i, anything(A), R.dead.find(A, ds, j), n, h, r, ts, R.dead.remove(A, ds, j), bs, d, lt, eh, er, find_other(A, ds, j, i, no), Unit{})
    case R.State{Q.State{n, h, r}, ts, ds, bs} R.Break{k, b}:
      g

def or_false_left(a: Bool, b: Bool, e: {Bool.or(a, b) == False{} : Bool}) -> {a == False{} : Bool}:
  match a:
    case True{}:
      Empty.absurd({True{} == False{} : Bool}, MNat.internal_false_ne_true(Equal.sym(Bool, True{}, False{}, e)))
    case False{}:
      {==}

def or_false_right(a: Bool, b: Bool, e: {Bool.or(a, b) == False{} : Bool}) -> {b == False{} : Bool}:
  match a:
    case True{}:
      Empty.absurd({b == False{} : Bool}, MNat.internal_false_ne_true(Equal.sym(Bool, True{}, False{}, e)))
    case False{}:
      e

def live_buried(~A: Data, +i: Nat, ops: List<&2, R.Op<A>>, +s: R.State<A>, g: inv(A, i, anything(A), s), +kept: {Laws.revives(A, ops, i) == False{} : Bool}) ->
    inv(A, i, anything(A), Laws.live(~A, ops, s)):
  match ops:
    case Nil{}:
      g
    case Con{op, +rest}:
      +op = op
      live_buried(~A, i, rest, R.step(~A, s, op), step_buried(~A, i, s, op, g, or_false_left(Laws.revived(A, op, i), Laws.revives(A, rest, i), kept)),
        or_false_right(Laws.revived(A, op, i), Laws.revives(A, rest, i), kept))

def absent_of_has(-A: Data, h: H.Heap<Q.Ticket<A>>, +i: Nat, +e: {Laws.has(A, h, i) == False{} : Bool}) -> absent.heap(A, h, i):
  match h:
    case H.HLeaf{}:
      Unit{}
    case H.HNode{n, +t, +l, +r}:
      +rest = or_false_right(Nat.is_eq(Q.id(A, t), i), Bool.or(Laws.has(A, l, i), Laws.has(A, r, i)), e)
      Both{or_false_left(Nat.is_eq(Q.id(A, t), i), Bool.or(Laws.has(A, l, i), Laws.has(A, r, i)), e),
        Both{absent_of_has(A, l, i, or_false_left(Laws.has(A, l, i), Laws.has(A, r, i), rest)), absent_of_has(A, r, i, or_false_right(Laws.has(A, l, i), Laws.has(A, r, i), rest))}}

def absent_of_has.dead(-A: Data, ds: List<&2, R.Dead<A>>, +i: Nat, +e: {Laws.has.dead(A, ds, i) == False{} : Bool}) -> absent.dead(A, i, ds):
  match ds:
    case Nil{}:
      Unit{}
    case Con{+d, +rest}:
      Both{or_false_left(Nat.is_eq(R.dead.id(A, d), i), Laws.has.dead(A, rest, i), e), absent_of_has.dead(A, rest, i, or_false_right(Nat.is_eq(R.dead.id(A, d), i), Laws.has.dead(A, rest, i), e))}

def finish_gone(~A: Data, +i: Nat, s: R.State<A>, fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s))), idle: {Laws.has(A, Q.pending(A, R.queue(A, s)), i) == False{} : Bool},
    alive: {Laws.has.dead(A, R.dead(A, s), i) == False{} : Bool}) -> gone(A, i, R.step(~A, s, R.Complete{i})):
  match s:
    case R.State{Q.State{n, +h, +r}, ts, +ds, bs}:
      complete_inv(~A, i, absent.dead(A, i), Q.take.list(A, r, i), n, h, R.tries.drop(ts, i), ds, bs, fresh, absent_of_has(A, h, i, idle), take_absent(A, r, i), absent_of_has.dead(A, ds, i, alive))

def cancel_gone(~A: Data, +i: Nat, s: R.State<A>, fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s)))) -> gone(A, i, R.step(~A, s, R.Cancel{i})):
  match s:
    case R.State{Q.State{n, +h, +r}, ts, +ds, bs}:
      Both{fresh, Both{remove_absent.heap(~A, h, i), Both{remove_absent.list(A, r, i), remove_absent.dead(A, ds, i)}}}

def abandon_buried(~A: Data, +i: Nat, s: R.State<A>, w: R.Why, fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s))), idle: {Laws.has(A, Q.pending(A, R.queue(A, s)), i) == False{} : Bool}) ->
    inv(A, i, anything(A), R.step(~A, s, R.Abandon{i, w})):
  match s:
    case R.State{Q.State{n, +h, +r}, ts, ds, bs}:
      abandon_inv(~A, i, anything(A), Q.take.list(A, r, i), n, h, R.tries.drop(ts, i), ds, bs, w, fresh, absent_of_has(A, h, i, idle), take_absent(A, r, i), Unit{})

def selected_absent(-A: Data, +i: Nat, m: Maybe<&2, Q.Ticket<A>>) -> Data:
  match m:
    case None{}:
      Unit
    case Some{t}:
      {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}

def select_selected_absent(~A: Data, now: Nat, +i: Nat, +q: Q.State<A>, eh: absent.heap(A, Q.pending(A, q), i)) -> selected_absent(A, i, Laws.selected(A, Q.select(~A, now, q))):
  match q:
    case Q.State{n, H.HLeaf{}, r}:
      Unit{}
    case Q.State{n, H.HNode{size, t, l, b}, r}:
      Both{et, Both{el, eb}} = eh
      split(c => selected_absent(A, i, Laws.selected(A, Q.select.due(~A, c, n, H.HNode{size, t, l, b}, r, t, l, b))), Nat.is_le(Q.deadline(A, t), now),
        e => et,
        e => Unit{})

# A Select from a state where i is neither pending nor running never takes i.
def never(~A: Data, now: Nat, +i: Nat, -P: List<&2, R.Dead<A>> -> Data, s: R.State<A>, g: inv(A, i, P, s), t: Q.Ticket<A>, e: {Laws.next(~A, now, s) == Some{t} : Maybe<&2, Q.Ticket<A>>}) ->
    {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}:
  match s:
    case R.State{Q.State{n, h, r}, ts, ds, bs}:
      Both{lt, Both{eh, rest}} = g
      %e : selected_absent(A, i, _)
      select_selected_absent(~A, now, i, Q.State{n, h, r}, eh)

def Laws.complete_never_selected(A, i, s, fresh, idle, alive, ops, now, t, e):
  +s = s
  +ops = ops
  never(~A, now, i, absent.dead(A, i), Laws.live(~A, ops, R.step(~A, s, R.Complete{i})), live_gone(~A, i, ops, R.step(~A, s, R.Complete{i}), finish_gone(~A, i, s, fresh, idle, alive)), t, e)

def Laws.cancel_never_selected(A, i, s, fresh, ops, now, t, e):
  +s = s
  +ops = ops
  never(~A, now, i, absent.dead(A, i), Laws.live(~A, ops, R.step(~A, s, R.Cancel{i})), live_gone(~A, i, ops, R.step(~A, s, R.Cancel{i}), cancel_gone(~A, i, s, fresh)), t, e)

def Laws.dead_never_selected(A, i, s, fresh, idle, w, ops, kept, now, t, e):
  +s = s
  +w = w
  +ops = ops
  never(~A, now, i, anything(A), Laws.live(~A, ops, R.step(~A, s, R.Abandon{i, w})), live_buried(~A, i, ops, R.step(~A, s, R.Abandon{i, w}), abandon_buried(~A, i, s, w, fresh, idle), kept), t, e)

def unsome(-T: Data, d: T, m: Maybe<&2, T>) -> T:
  match m:
    case None{}:
      d
    case Some{x}:
      x

def some_inj(-T: Data, +a: T, b: T, e: {Some{a} == Some{b} : Maybe<&2, T>}) -> {a == b : T}:
  %e : {a == unsome(T, a, _) : T}
  {==}

def moved(-A: Data, +i: Nat, x: R.State<A>, y: R.State<A>, q: {x == y : R.State<A>}, g: gone(A, i, x)) -> gone(A, i, y):
  %q : gone(A, i, _)
  g

def Laws.recovered_never_selected(A, X, enc, dec, round, i, s, fresh, idle, alive, ops, r, back, now, t, e):
  +r = r
  +s1 = R.step(~A, s, R.Complete{i})
  +q = some_inj(R.State<A>, Laws.live(~A, ops, s1), r,
    Equal.trans(Maybe<&2, R.State<A>>, Some{Laws.live(~A, ops, s1)}, Laws.replayed(~A, ~X, ~enc, ~dec, ops, s1), Some{r},
      Equal.sym(Maybe<&2, R.State<A>>, Laws.replayed(~A, ~X, ~enc, ~dec, ops, s1), Some{Laws.live(~A, ops, s1)}, replay.go(~A, ~X, ~enc, ~dec, ~round, ops, s1)), back))
  never(~A, now, i, absent.dead(A, i), r, moved(A, i, Laws.live(~A, ops, s1), r, q, live_gone(~A, i, ops, s1, finish_gone(~A, i, s, fresh, idle, alive))), t, e)
