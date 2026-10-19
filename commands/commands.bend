# Retry-safe commands: deduplicate by command id, replay recorded results, and commit state, record, and outbox in one SQLite transaction. Source: https://github.com/paymog/bend-kit/tree/main/commands
import Base
import bend-kit-sqlite@0.1.0.1/sqlite.bend as Sqlite

# ---- the pure processor

type Outcome<-R: Data> is Data:
  Accepted{result: R}
  Refused{result: R}

# What the store keeps for one command id: its payload, its outcome, and when it was recorded.
type Record<-P: Data, -R: Data> is Data:
  Record{payload: P, outcome: Outcome<R>, at: U32}

type Reply<-R: Data> is Data:
  Fresh{outcome: Outcome<R>}
  Replayed{outcome: Outcome<R>}
  Conflict{}

# The domain's answer to a new command.
type Decision<-S: Data, -R: Data, -E: Data> is Data:
  Accept{state: S, result: R, effects: List<&2, E>}
  Refuse{result: R}

# Write: commit the state, the record, and the effects together. Keep: write nothing.
type Step<-S: Data, -P: Data, -R: Data, -E: Data> is Data:
  Write{state: S, record: Record<P, R>, reply: Reply<R>, effects: List<&2, E>}
  Keep{reply: Reply<R>}

def decided(-S: Data, -P: Data, -R: Data, -E: Data, d: Decision<S, R, E>, s: S, p: P, at: U32) -> Step<S, P, R, E>:
  match d:
    case Accept{s2, +r, es}:
      Write{s2, Record{p, Accepted{r}, at}, Fresh{Accepted{r}}, es}
    case Refuse{+r}:
      Write{s, Record{p, Refused{r}, at}, Fresh{Refused{r}}, Nil{}}

def replayed(-R: Data, same: Bool, o: Outcome<R>) -> Reply<R>:
  match same:
    case True{}:
      Replayed{o}
    case False{}:
      Conflict{}

# One command, given the record that the store holds for its id and the domain state s.
def step(
  ~S: Data, ~P: Data, ~R: Data, ~E: Data, ~eq: P -> P -> Bool, ~decide: S -> P -> Decision<S, R, E>,
  found: Maybe<&2, Record<P, R>>, +s: S, +p: P, at: U32
) -> Step<S, P, R, E>:
  match found:
    case None{}:
      decided(S, P, R, E, decide(s, p), s, p, at)
    case Some{Record{q, o, t}}:
      Keep{replayed(R, eq(q, p), o)}

# ---- IO that can fail with a SQLite error

def Run(-A: Type) -> Type:
  IO(Result<&1, &1, U32 & String, A>)

def Run.pure(-A: Type, x: A) -> Run(A):
  IO.pure(Result<&1, &1, U32 & String, A>, Done{x})

def Run.fail(-A: Type, e: U32 & String) -> Run(A):
  IO.pure(Result<&1, &1, U32 & String, A>, Fail{e})

def Run.next(-A: Type, -B: Type, r: Result<&1, &1, U32 & String, A>, f: A -> Run(B)) -> Run(B):
  match r:
    case Done{x}:
      f(x)
    case Fail{e}:
      Run.fail(B, e)

def Run.bind(-A: Type, -B: Type, m: Run(A), f: A -> Run(B)) -> Run(B):
  IO.bind(Result<&1, &1, U32 & String, A>, Result<&1, &1, U32 & String, B>, m, r => Run.next(A, B, r, f))

# r's value, unless r or then z failed.
def first(-A: Type, r: Result<&1, &1, U32 & String, A>, z: Result<&1, &1, U32 & String, Unit>) -> Result<&1, &1, U32 & String, A>:
  match r z:
    case Fail{e} _:
      Fail{e}
    case Done{x} Fail{e}:
      Fail{e}
    case Done{x} Done{u}:
      Done{x}

def unit(-A: Type, r: Result<&1, &1, U32 & String, A>) -> Result<&1, &1, U32 & String, Unit>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{x}:
      Done{Unit{}}

# ---- SQLite helpers

# Steps a statement and ignores any row, then resets it, also after a failed step.
def exec(+stmt: U32) -> Run(Unit):
  do IO<Result<&1, &1, U32 & String, Unit>>:
    r : Result<&1, &1, U32 & String, Bool> <- Sqlite.stmt.step(stmt)
    z : Result<&1, &1, U32 & String, Unit> <- Sqlite.stmt.reset(stmt)
    return first(Unit, unit(Bool, r), z)

def once.run(-A: Type, +s: U32, body: U32 -> Run(A)) -> Run(A):
  do IO<Result<&1, &1, U32 & String, A>>:
    r : Result<&1, &1, U32 & String, A> <- body(s)
    z : Result<&1, &1, U32 & String, Unit> <- Sqlite.stmt.finalize(s)
    return first(A, r, z)

# Prepares one statement, runs body on it, and finalizes it, also after body fails.
def once(-A: Type, +db: U32, text: String, body: U32 -> Run(A)) -> Run(A):
  do Run<A>:
    s : U32 <- Sqlite.stmt.prepare(db, text)
    once.run(A, s, body)

def sql(+db: U32, text: String) -> Run(Unit):
  once(Unit, db, text, +s => exec(s))

# ---- the store

# A database and its prepared statements. One Store serves one task at a time.
type Store is Data:
  Store{db: U32, begin: U32, commit: U32, rollback: U32, find: U32, read: U32, save: U32, keep: U32, emit: U32}

def init.run(+s: U32, init: String) -> Run(Unit):
  do Run<Unit>:
    Sqlite.stmt.bind.text(s, 1, init)
    exec(s)

# Opens or creates the tables at path. A new database starts with domain state init.
# wait is how many ms a write waits for another connection's transaction before it fails with SQLITE_BUSY (5).
def open(path: String, init: String, wait: U32) -> Run(Store):
  do Run<Store>:
    +db : U32 <- Sqlite.db.open(path)
    sql(db, "PRAGMA busy_timeout = " ++ U32.show(wait))
    sql(db, "CREATE TABLE IF NOT EXISTS commands_state (k INTEGER PRIMARY KEY CHECK (k = 0), state TEXT NOT NULL)")
    sql(db, "CREATE TABLE IF NOT EXISTS commands_seen (id TEXT PRIMARY KEY, payload TEXT NOT NULL, kind INTEGER NOT NULL, result TEXT NOT NULL, at INTEGER NOT NULL)")
    sql(db, "CREATE INDEX IF NOT EXISTS commands_seen_at ON commands_seen (at)")
    sql(db, "CREATE TABLE IF NOT EXISTS commands_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, effect TEXT NOT NULL)")
    once(Unit, db, "INSERT OR IGNORE INTO commands_state (k, state) VALUES (0, ?)", +s => init.run(s, init))
    begin : U32 <- Sqlite.stmt.prepare(db, "BEGIN IMMEDIATE")
    commit : U32 <- Sqlite.stmt.prepare(db, "COMMIT")
    rollback : U32 <- Sqlite.stmt.prepare(db, "ROLLBACK")
    find : U32 <- Sqlite.stmt.prepare(db, "SELECT payload, kind, result, at FROM commands_seen WHERE id = ?")
    read : U32 <- Sqlite.stmt.prepare(db, "SELECT state FROM commands_state WHERE k = 0")
    save : U32 <- Sqlite.stmt.prepare(db, "UPDATE commands_state SET state = ? WHERE k = 0")
    keep : U32 <- Sqlite.stmt.prepare(db, "INSERT INTO commands_seen (id, payload, kind, result, at) VALUES (?, ?, ?, ?, ?)")
    emit : U32 <- Sqlite.stmt.prepare(db, "INSERT INTO commands_outbox (id, effect) VALUES (?, ?)")
    return Store{db, begin, commit, rollback, find, read, save, keep, emit}

def close(st: Store) -> Run(Unit):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  do Run<Unit>:
    Sqlite.stmt.finalize(begin)
    Sqlite.stmt.finalize(commit)
    Sqlite.stmt.finalize(rollback)
    Sqlite.stmt.finalize(find)
    Sqlite.stmt.finalize(read)
    Sqlite.stmt.finalize(save)
    Sqlite.stmt.finalize(keep)
    Sqlite.stmt.finalize(emit)
    Sqlite.db.close(db)

def outcome(+kind: U32, +r: String) -> Outcome<String>:
  Bool.pick(Outcome<String>, U32.is_eq(kind, 1), Accepted{r}, Refused{r})

def seen.row(row: Bool, +find: U32) -> Run(Maybe<&2, Record<String, String>>):
  match row:
    case False{}:
      Run.pure(Maybe<&2, Record<String, String>>, None{})
    case True{}:
      do Run<Maybe<&2, Record<String, String>>>:
        p : String <- Sqlite.stmt.column.text(find, 0)
        kind : U32 <- Sqlite.stmt.column.int(find, 1)
        r : String <- Sqlite.stmt.column.text(find, 2)
        at : U32 <- Sqlite.stmt.column.int(find, 3)
        return Some{Record{p, outcome(kind, r), at}}

# The record for id, if the store holds one.
def seen.get(+find: U32, id: String) -> Run(Maybe<&2, Record<String, String>>):
  do Run<Maybe<&2, Record<String, String>>>:
    Sqlite.stmt.bind.text(find, 1, id)
    row : Bool <- Sqlite.stmt.step(find)
    m : Maybe<&2, Record<String, String>> <- seen.row(row, find)
    Sqlite.stmt.reset(find)
    return m

def state.row(row: Bool, +read: U32) -> Run(String):
  match row:
    case True{}:
      Sqlite.stmt.column.text(read, 0)
    case False{}:
      Run.fail(String, (1, "commands: the state row is missing"))

def state.get(+read: U32) -> Run(String):
  do Run<String>:
    row : Bool <- Sqlite.stmt.step(read)
    s : String <- state.row(row, read)
    Sqlite.stmt.reset(read)
    return s

def seen.put.row(+keep: U32, id: String, p: String, kind: U32, r: String, at: U32) -> Run(Unit):
  do Run<Unit>:
    Sqlite.stmt.bind.text(keep, 1, id)
    Sqlite.stmt.bind.text(keep, 2, p)
    Sqlite.stmt.bind.int(keep, 3, kind)
    Sqlite.stmt.bind.text(keep, 4, r)
    Sqlite.stmt.bind.int(keep, 5, at)
    exec(keep)

def seen.put.of(o: Outcome<String>, +keep: U32, id: String, p: String, at: U32) -> Run(Unit):
  match o:
    case Accepted{r}:
      seen.put.row(keep, id, p, 1, r, at)
    case Refused{r}:
      seen.put.row(keep, id, p, 2, r, at)

def seen.put(rec: Record<String, String>, +keep: U32, id: String) -> Run(Unit):
  Record{p, o, at} = rec
  seen.put.of(o, keep, id, p, at)

def outbox.put(es: List<&2, String>, +emit: U32, +id: String) -> Run(Unit):
  match es:
    case Nil{}:
      Run.pure(Unit, Unit{})
    case Con{e, rest}:
      do Run<Unit>:
        Sqlite.stmt.bind.text(emit, 1, id)
        Sqlite.stmt.bind.text(emit, 2, e)
        exec(emit)
        outbox.put(rest, emit, id)

def state.put(+save: U32, s: String) -> Run(Unit):
  do Run<Unit>:
    Sqlite.stmt.bind.text(save, 1, s)
    exec(save)

# Applies a step inside the open transaction, then commits it.
def written(w: Step<String, String, String, String>, +commit: U32, +save: U32, +keep: U32, +emit: U32, +id: String) -> Run(Reply<String>):
  match w:
    case Write{s, rec, reply, es}:
      do Run<Reply<String>>:
        state.put(save, s)
        seen.put(rec, keep, id)
        outbox.put(es, emit, id)
        exec(commit)
        return reply
    case Keep{reply}:
      do Run<Reply<String>>:
        exec(commit)
        return reply

def handle.txn(~decide: String -> String -> Decision<String, String, String>, st: Store, +id: String, payload: String, at: U32) -> Run(Reply<String>):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  do Run<Reply<String>>:
    exec(begin)
    found : Maybe<&2, Record<String, String>> <- seen.get(find, id)
    s : String <- state.get(read)
    written(step(~String, ~String, ~String, ~String, ~String.eq, ~decide, found, s, payload, at), commit, save, keep, emit, id)

# On failure, resets the read statements and rolls back. Rollback errors are ignored: the transaction may not have started.
def handle.end(r: Result<&1, &1, U32 & String, Reply<String>>, st: Store) -> Run(Reply<String>):
  match r:
    case Done{x}:
      Run.pure(Reply<String>, x)
    case Fail{e}:
      Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
      do IO<Result<&1, &1, U32 & String, Reply<String>>>:
        a : Result<&1, &1, U32 & String, Unit> <- Sqlite.stmt.reset(find)
        b : Result<&1, &1, U32 & String, Unit> <- Sqlite.stmt.reset(read)
        c : Result<&1, &1, U32 & String, Unit> <- exec(rollback)
        return Fail{e}

# Runs one command in one transaction: find its record, decide, and commit state, record, and effects.
# at is the record's time for prune, in seconds. decide sees the committed state and the payload.
def handle(~decide: String -> String -> Decision<String, String, String>, +st: Store, id: String, payload: String, at: U32) -> Run(Reply<String>):
  do IO<Result<&1, &1, U32 & String, Reply<String>>>:
    r : Result<&1, &1, U32 & String, Reply<String>> <- handle.txn(~decide, st, id, payload, at)
    handle.end(r, st)

# The committed domain state.
def state(st: Store) -> Run(String):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  state.get(read)

def prune.run(+s: U32, before: U32) -> Run(Unit):
  do Run<Unit>:
    Sqlite.stmt.bind.int(s, 1, before)
    exec(s)

# Forgets every record made before the time before. A later retry of a forgotten id runs as a new command.
def prune(st: Store, before: U32) -> Run(Unit):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  once(Unit, db, "DELETE FROM commands_seen WHERE at < ?", +s => prune.run(s, before))

# An undelivered effect: its sequence number, its command id, and the effect.
type Pending is Data:
  Pending{seq: U32, id: String, effect: String}

def outbox.row(row: Bool, +s: U32) -> Run(Maybe<&2, Pending>):
  match row:
    case False{}:
      Run.pure(Maybe<&2, Pending>, None{})
    case True{}:
      do Run<Maybe<&2, Pending>>:
        seq : U32 <- Sqlite.stmt.column.int(s, 0)
        id : String <- Sqlite.stmt.column.text(s, 1)
        e : String <- Sqlite.stmt.column.text(s, 2)
        return Some{Pending{seq, id, e}}

def outbox.first(+s: U32) -> Run(Maybe<&2, Pending>):
  do Run<Maybe<&2, Pending>>:
    row : Bool <- Sqlite.stmt.step(s)
    outbox.row(row, s)

# The oldest undelivered effect.
def outbox.next(st: Store) -> Run(Maybe<&2, Pending>):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  once(Maybe<&2, Pending>, db, "SELECT seq, id, effect FROM commands_outbox ORDER BY seq LIMIT 1", +s => outbox.first(s))

def outbox.ack.run(+s: U32, seq: U32) -> Run(Unit):
  do Run<Unit>:
    Sqlite.stmt.bind.int(s, 1, seq)
    exec(s)

# Removes a delivered effect. Deliver before ack: a crash between them delivers the effect again.
def outbox.ack(st: Store, seq: U32) -> Run(Unit):
  Store{db, begin, commit, rollback, find, read, save, keep, emit} = st
  once(Unit, db, "DELETE FROM commands_outbox WHERE seq = ?", +s => outbox.ack.run(s, seq))
