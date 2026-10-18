import Base
import bend-mathlib@0.7.2.0/nat.bend as MNat
import bend-kit-scheduler@0.3.0.0/queue.bend as Q
import bend-kit-collections@0.1.3.0/heap.bend as H
import bend-kit-resources@0.1.0.0/resources.bend as Res
import bend-kit-retry@0.1.0.0/retry.bend as Retry
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

# ---- retry

def Laws.requeue_wait(A, o, p, b, id, n, now, r, w, e):
  %Equal.sym(Retry.Plan, Retry.plan(o, p, b, n, now, r), Retry.PlanWait{w}, e) : {R.after.plan(A, _, id, now) == R.Requeue{id, Nat.add(now, w)} : R.Op<A>}
  {==}

def Laws.requeue_stop(A, o, p, b, id, n, now, r, e):
  %Equal.sym(Retry.Plan, Retry.plan(o, p, b, n, now, r), Retry.PlanStop{}, e) : {R.after.plan(A, _, id, now) == R.Complete{id} : R.Op<A>}
  {==}

# ---- pool

# Every pick is Idle with the pool unchanged, or the reserve of one unit for a selected ticket.
def pick_cases(~A: Data, -P: R.Pick<A> -> Type, +p: Res.Pool, s: R.State<A>, +now: Nat, idle: P(R.Idle{p}),
    took: @t: Q.Ticket<A> -> P(R.pick.took(A, Res.reserve(p, 1n), t))) -> P(R.pick(~A, p, s, now)):
  match s:
    case R.State{Q.State{i, H.HLeaf{}, r}, ts}:
      idle
    case R.State{Q.State{i, H.HNode{n, +t, l, q}, r}, ts}:
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

# Ticket i is in no registry of s, and s will issue no id i again.
def gone(-A: Data, +i: Nat, s: R.State<A>) -> Data:
  match s:
    case R.State{Q.State{n, h, r}, ts}:
      Both<MNat.lt(i, n), Both<absent.heap(A, h, i), absent.list(A, r, i)>>

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

def complete_gone(~A: Data, +i: Nat, tk: Q.Taken<A>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, ts: R.Tries(), lt: MNat.lt(i, n), eh: absent.heap(A, h, i), erem: taken.rem_ok(A, tk, i)) ->
    gone(A, i, R.step.completed(A, Q.complete.taken(A, tk, n, h), ts)):
  match tk:
    case Q.Taken{rest, found}:
      Both{lt, Both{eh, erem}}

def requeue_gone(~A: Data, +i: Nat, tk: Q.Taken<A>, +n: Nat, +h: H.Heap<Q.Ticket<A>>, +d: Nat, ts: R.Tries(), lt: MNat.lt(i, n), eh: absent.heap(A, h, i), etk: taken.ok(A, tk, i)) ->
    gone(A, i, R.step.requeued(A, Q.requeue.completed(~A, Q.complete.taken(A, tk, n, h), d), ts)):
  match tk:
    case Q.Taken{rest, None{}}:
      Both{erest, ef} = etk
      Both{lt, Both{eh, erest}}
    case Q.Taken{rest, Some{Q.Ticket{j, old, x}}}:
      Both{erest, ej} = etk
      Both{lt, Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{j, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{ej, Both{Unit{}, Unit{}}}, eh), erest}}

def select_gone(~A: Data, +i: Nat, +now: Nat, +n: Nat, h: H.Heap<Q.Ticket<A>>, r: List<&2, Q.Ticket<A>>, ts: R.Tries(), +lt: MNat.lt(i, n), +eh: absent.heap(A, h, i), +er: absent.list(A, r, i)) ->
    gone(A, i, R.step.selected(A, Q.select(~A, now, Q.State{n, h, r}), ts)):
  match h:
    case H.HLeaf{}:
      Both{lt, Both{eh, er}}
    case H.HNode{size, +t, +l, +q}:
      Both{+et, Both{+el, +eq}} = eh
      split(c => gone(A, i, R.step.selected(A, Q.select.due(~A, c, n, H.HNode{size, t, l, q}, r, t, l, q), ts)), Nat.is_le(Q.deadline(A, t), now),
        e => Both{lt, Both{merge_all.full(~A, absent.ticket(A, i), l, q, el, eq), Both{et, er}}},
        e => Both{lt, Both{Both{et, Both{el, eq}}, er}})

# Every op keeps a gone ticket gone.
def step_gone(~A: Data, +i: Nat, s: R.State<A>, op: R.Op<A>, g: gone(A, i, s)) -> gone(A, i, R.step(~A, s, op)):
  match s op:
    case R.State{Q.State{+n, h, r}, ts} R.Enqueue{d, x}:
      Both{+lt, Both{eh, er}} = g
      Both{MNat.lt_trans(i, n, 1n+n, lt, MNat.lt_succ_self(n)), Both{merge_all.full(~A, absent.ticket(A, i), H.HNode{1n, Q.Ticket{n, d, x}, H.HLeaf{}, H.HLeaf{}}, h, Both{lt_ne(i, n, lt), Both{Unit{}, Unit{}}}, eh), er}}
    case R.State{Q.State{n, h, r}, ts} R.Select{now}:
      Both{lt, Both{eh, er}} = g
      select_gone(~A, i, now, n, h, r, ts, lt, eh, er)
    case R.State{Q.State{n, h, +r}, ts} R.Complete{+j}:
      Both{lt, Both{eh, er}} = g
      complete_gone(~A, i, Q.take.list(A, r, j), n, h, R.tries.drop(ts, j), lt, eh, ok_rem(A, Q.take.list(A, r, j), i, take_ok(A, r, j, i, er)))
    case R.State{Q.State{n, h, +r}, ts} R.Cancel{+j}:
      Both{lt, Both{eh, er}} = g
      Both{lt, Both{remove_all(~A, absent.ticket(A, i), h, j, eh), remove_keeps.list(A, r, j, i, er)}}
    case R.State{Q.State{n, h, +r}, ts} R.Requeue{+j, d}:
      Both{lt, Both{eh, er}} = g
      requeue_gone(~A, i, Q.take.list(A, r, j), n, h, d, R.tries.bump(ts, j), lt, eh, take_ok(A, r, j, i, er))
    case R.State{Q.State{n, h, +r}, ts} R.Defer{+j, d}:
      Both{lt, Both{eh, er}} = g
      requeue_gone(~A, i, Q.take.list(A, r, j), n, h, d, ts, lt, eh, take_ok(A, r, j, i, er))

def live_gone(~A: Data, +i: Nat, ops: List<&2, R.Op<A>>, +s: R.State<A>, g: gone(A, i, s)) -> gone(A, i, Laws.live(~A, ops, s)):
  match ops:
    case Nil{}:
      g
    case Con{op, rest}:
      +op = op
      live_gone(~A, i, rest, R.step(~A, s, op), step_gone(~A, i, s, op, g))

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

def absent_of_has(-A: Data, h: H.Heap<Q.Ticket<A>>, +i: Nat, +e: {Laws.has(A, h, i) == False{} : Bool}) -> absent.heap(A, h, i):
  match h:
    case H.HLeaf{}:
      Unit{}
    case H.HNode{n, +t, +l, +r}:
      +rest = or_false_right(Nat.is_eq(Q.id(A, t), i), Bool.or(Laws.has(A, l, i), Laws.has(A, r, i)), e)
      Both{or_false_left(Nat.is_eq(Q.id(A, t), i), Bool.or(Laws.has(A, l, i), Laws.has(A, r, i)), e),
        Both{absent_of_has(A, l, i, or_false_left(Laws.has(A, l, i), Laws.has(A, r, i), rest)), absent_of_has(A, r, i, or_false_right(Laws.has(A, l, i), Laws.has(A, r, i), rest))}}

def finish_gone(~A: Data, +i: Nat, s: R.State<A>, fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s))), idle: {Laws.has(A, Q.pending(A, R.queue(A, s)), i) == False{} : Bool}) ->
    gone(A, i, R.step(~A, s, R.Complete{i})):
  match s:
    case R.State{Q.State{n, +h, +r}, ts}:
      complete_gone(~A, i, Q.take.list(A, r, i), n, h, R.tries.drop(ts, i), fresh, absent_of_has(A, h, i, idle), take_absent(A, r, i))

def cancel_gone(~A: Data, +i: Nat, s: R.State<A>, fresh: MNat.lt(i, Q.next_id(A, R.queue(A, s)))) -> gone(A, i, R.step(~A, s, R.Cancel{i})):
  match s:
    case R.State{Q.State{n, +h, +r}, ts}:
      Both{fresh, Both{remove_absent.heap(~A, h, i), remove_absent.list(A, r, i)}}

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

# A Select from a state where i is gone never takes i.
def never(~A: Data, now: Nat, +i: Nat, s: R.State<A>, g: gone(A, i, s), t: Q.Ticket<A>, e: {Laws.next(~A, now, s) == Some{t} : Maybe<&2, Q.Ticket<A>>}) -> {Nat.is_eq(Q.id(A, t), i) == False{} : Bool}:
  match s:
    case R.State{Q.State{n, h, r}, ts}:
      Both{lt, Both{eh, er}} = g
      %e : selected_absent(A, i, _)
      select_selected_absent(~A, now, i, Q.State{n, h, r}, eh)

def Laws.complete_never_selected(A, i, s, fresh, idle, ops, now, t, e):
  +s = s
  +ops = ops
  never(~A, now, i, Laws.live(~A, ops, R.step(~A, s, R.Complete{i})), live_gone(~A, i, ops, R.step(~A, s, R.Complete{i}), finish_gone(~A, i, s, fresh, idle)), t, e)

def Laws.cancel_never_selected(A, i, s, fresh, ops, now, t, e):
  +s = s
  +ops = ops
  never(~A, now, i, Laws.live(~A, ops, R.step(~A, s, R.Cancel{i})), live_gone(~A, i, ops, R.step(~A, s, R.Cancel{i}), cancel_gone(~A, i, s, fresh)), t, e)

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

def Laws.recovered_never_selected(A, X, enc, dec, round, i, s, fresh, idle, ops, r, back, now, t, e):
  +r = r
  +s1 = R.step(~A, s, R.Complete{i})
  +q = some_inj(R.State<A>, Laws.live(~A, ops, s1), r,
    Equal.trans(Maybe<&2, R.State<A>>, Some{Laws.live(~A, ops, s1)}, Laws.replayed(~A, ~X, ~enc, ~dec, ops, s1), Some{r},
      Equal.sym(Maybe<&2, R.State<A>>, Laws.replayed(~A, ~X, ~enc, ~dec, ops, s1), Some{Laws.live(~A, ops, s1)}, replay.go(~A, ~X, ~enc, ~dec, ~round, ops, s1)), back))
  never(~A, now, i, r, moved(A, i, Laws.live(~A, ops, s1), r, q, live_gone(~A, i, ops, s1, finish_gone(~A, i, s, fresh, idle))), t, e)
