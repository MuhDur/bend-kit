# A payment ledger fed by webhook events: each event id is a command id, so a redelivered event applies once.
import Base
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
import bend-kit-json@0.6.1.1/json.bend as Json
import bend-kit-collections@0.1.3.0/omap.bend as O
import ./commands.bend as C

# ---- state: a JSON object of account balances, such as {"acct_1":500}

def Books() -> Data:
  O.OMap<String, U32>

def books.put.n(n: Maybe<&2, U32>, m: Maybe<&2, Books()>, +k: String) -> Maybe<&2, Books()>:
  match n m:
    case Some{x} Some{b}:
      Some{O.OMap.put(~String, ~U32, ~String.order, b, k, x)}
    case _ _:
      None{}

def books.put(v: Json.Val, +k: String, m: Maybe<&2, Books()>) -> Maybe<&2, Books()>:
  match v:
    case Json.Num{b}:
      books.put.n(U32.read(Bytes.to_string(b)), m, k)
    case _:
      None{}

def books.add(kvs: List<&1, Bytes.Bytes & Json.Val>, m: Maybe<&2, Books()>) -> Maybe<&2, Books()>:
  match kvs:
    case Nil{}:
      m
    case Con{kv, rest}:
      (k, v) = kv
      books.add(rest, books.put(v, Bytes.to_string(k), m))

def books.of(mv: Maybe<&1, Json.Val>) -> Maybe<&2, Books()>:
  match mv:
    case Some{Json.Obj{kvs}}:
      books.add(kvs, Some{O.OMap.new(String, U32)})
    case _:
      None{}

def decode(s: String) -> Maybe<&2, Books()>:
  books.of(Json.parse.strict.unique.bytes(Bytes.from_string(s), 1))

def encode.go(xs: List<&1, String & U32>) -> List<&1, Bytes.Bytes & Json.Val>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{kv, rest}:
      (k, n) = kv
      Con{(Bytes.from_string(k), Json.Num{Bytes.from_string(U32.show(n))}), encode.go(rest)}

def encode(m: Books()) -> String:
  Bytes.to_string(Json.encode.bytes(Json.Obj{encode.go(O.OMap.to_list(String, U32, m))}))

# ---- payload: {"account":"acct_1","credit":500} or {"account":"acct_1","debit":200}

type Op is Data:
  Credit{account: String, amount: U32}
  Debit{account: String, amount: U32}

type Fields is Data:
  Fields{account: Maybe<&2, String>, credit: Maybe<&2, U32>, debit: Maybe<&2, U32>}

def field.str(+k: String, +s: String, f: Fields) -> Fields:
  Fields{+a, +c, +d} = f
  Bool.pick(Fields, String.eq(k, "account"), Fields{Some{s}, c, d}, Fields{a, c, d})

def field.num(+k: String, +n: Maybe<&2, U32>, f: Fields) -> Fields:
  Fields{+a, +c, +d} = f
  Bool.pick(Fields, String.eq(k, "credit"), Fields{a, n, d}, Bool.pick(Fields, String.eq(k, "debit"), Fields{a, c, n}, Fields{a, c, d}))

def field(v: Json.Val, +k: String, f: Fields) -> Fields:
  match v:
    case Json.Str{b}:
      field.str(k, Bytes.to_string(b), f)
    case Json.Num{b}:
      field.num(k, U32.read(Bytes.to_string(b)), f)
    case _:
      f

def fields(kvs: List<&1, Bytes.Bytes & Json.Val>, f: Fields) -> Fields:
  match kvs:
    case Nil{}:
      f
    case Con{kv, rest}:
      (k, v) = kv
      fields(rest, field(v, Bytes.to_string(k), f))

def op.of(f: Fields) -> Maybe<&2, Op>:
  match f:
    case Fields{Some{a}, Some{n}, None{}}:
      Some{Credit{a, n}}
    case Fields{Some{a}, None{}, Some{n}}:
      Some{Debit{a, n}}
    case _:
      None{}

def payload.of(mv: Maybe<&1, Json.Val>) -> Maybe<&2, Op>:
  match mv:
    case Some{Json.Obj{kvs}}:
      op.of(fields(kvs, Fields{None{}, None{}, None{}}))
    case _:
      None{}

# Strict UTF-8 JSON with unique keys. Callers send one canonical encoding per event: the bytes are the identity.
def payload(p: String) -> Maybe<&2, Op>:
  payload.of(Json.parse.strict.unique.bytes(Bytes.from_string(p), 1))

# ---- decide

def balance(m: Maybe<&2, U32>) -> U32:
  match m:
    case Some{x}:
      x
    case None{}:
      0

def accepted(m: Books(), +a: String, +n: U32) -> C.Decision<String, String, String>:
  C.Accept{encode(O.OMap.put(~String, ~U32, ~String.order, m, a, n)), U32.show(n), [a ++ "=" ++ U32.show(n)]}

def settle(ok: Bool, m: Books(), +a: String, +n: U32, why: String) -> C.Decision<String, String, String>:
  match ok:
    case True{}:
      accepted(m, a, n)
    case False{}:
      C.Refuse{why}

def apply(o: Op, +m: Books()) -> C.Decision<String, String, String>:
  match o:
    case Credit{+a, +n}:
      +b = balance(O.OMap.get(~String, ~U32, ~String.order, m, a))
      +t = (b + n : U32)
      settle(U32.is_le(b, t), m, a, t, "balance overflow")
    case Debit{+a, +n}:
      +b = balance(O.OMap.get(~String, ~U32, ~String.order, m, a))
      settle(U32.is_le(n, b), m, a, (b - n : U32), "insufficient funds")

def decide.go(m: Maybe<&2, Books()>, o: Maybe<&2, Op>) -> C.Decision<String, String, String>:
  match m o:
    case Some{b} Some{x}:
      apply(x, b)
    case None{} _:
      C.Refuse{"state does not decode"}
    case Some{b} None{}:
      C.Refuse{"invalid payload"}

# A credit or debit of one account. The result is the new balance; the effect notifies the account holder.
def decide(s: String, p: String) -> C.Decision<String, String, String>:
  decide.go(decode(s), payload(p))

def outcome.show(o: C.Outcome<String>) -> String:
  match o:
    case C.Accepted{r}:
      "accepted " ++ r
    case C.Refused{r}:
      "refused " ++ r

def reply.show(r: C.Reply<String>) -> String:
  match r:
    case C.Fresh{o}:
      "fresh " ++ outcome.show(o)
    case C.Replayed{o}:
      "replayed " ++ outcome.show(o)
    case C.Conflict{}:
      "conflict"
