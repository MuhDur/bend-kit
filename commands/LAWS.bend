import Base
import ./commands.bend as C

# Each law holds for every domain: any state, payload, result, and effect types, any payload
# comparison eq, and any decide. `found` is the record that the store holds for the command's id.

# ---- a record exists for the id

# A duplicate: the payload equals the recorded one. Nothing is written, no effect is emitted,
# and the reply is the recorded outcome.
law duplicate_replays:
  for ~S: Data
  for ~P: Data
  for ~R: Data
  for ~E: Data
  for ~eq: P -> P -> Bool
  for ~decide: S -> P -> C.Decision<S, R, E>
  for +q: P
  for o: C.Outcome<R>
  for t: U32
  for +p: P
  for same: {eq(q, p) == True{} : Bool}
  for s: S
  for at: U32
  {C.step(~S, ~P, ~R, ~E, ~eq, ~decide, Some{C.Record{q, o, t}}, s, p, at) == C.Keep{C.Replayed{o}} : C.Step<S, P, R, E>}

# The id is reused with a different payload. It is rejected: nothing is written and no effect is emitted.
law conflict_rejected:
  for ~S: Data
  for ~P: Data
  for ~R: Data
  for ~E: Data
  for ~eq: P -> P -> Bool
  for ~decide: S -> P -> C.Decision<S, R, E>
  for +q: P
  for o: C.Outcome<R>
  for t: U32
  for +p: P
  for differ: {eq(q, p) == False{} : Bool}
  for s: S
  for at: U32
  {C.step(~S, ~P, ~R, ~E, ~eq, ~decide, Some{C.Record{q, o, t}}, s, p, at) == C.Keep{C.Conflict{}} : C.Step<S, P, R, E>}

# ---- no record for the id

# An accepted command writes the state that decide gave, its effects, and a record of exactly the result it replies.
law accept_recorded:
  for ~S: Data
  for ~P: Data
  for ~R: Data
  for ~E: Data
  for ~eq: P -> P -> Bool
  for ~decide: S -> P -> C.Decision<S, R, E>
  for +s: S
  for +p: P
  for at: U32
  for s2: S
  for r: R
  for es: List<&2, E>
  for e: {decide(s, p) == C.Accept{s2, r, es} : C.Decision<S, R, E>}
  {C.step(~S, ~P, ~R, ~E, ~eq, ~decide, None{}, s, p, at) == C.Write{s2, C.Record{p, C.Accepted{r}, at}, C.Fresh{C.Accepted{r}}, es} : C.Step<S, P, R, E>}

# A refused command keeps the domain state and emits no effect. Its result is recorded, so a retry gets the same answer.
law refuse_keeps_state:
  for ~S: Data
  for ~P: Data
  for ~R: Data
  for ~E: Data
  for ~eq: P -> P -> Bool
  for ~decide: S -> P -> C.Decision<S, R, E>
  for +s: S
  for +p: P
  for at: U32
  for r: R
  for e: {decide(s, p) == C.Refuse{r} : C.Decision<S, R, E>}
  {C.step(~S, ~P, ~R, ~E, ~eq, ~decide, None{}, s, p, at) == C.Write{s, C.Record{p, C.Refused{r}, at}, C.Fresh{C.Refused{r}}, Nil{}} : C.Step<S, P, R, E>}

# ---- a retry after the first commit

# The step that a retry runs against what w committed: its record and its state.
def retried(
  ~S: Data, ~P: Data, ~R: Data, ~E: Data, ~eq: P -> P -> Bool, ~decide: S -> P -> C.Decision<S, R, E>,
  w: C.Step<S, P, R, E>, +p: P, at: U32
) -> C.Step<S, P, R, E>:
  match w:
    case C.Write{s, rec, reply, es}:
      C.step(~S, ~P, ~R, ~E, ~eq, ~decide, Some{rec}, s, p, at)
    case C.Keep{reply}:
      C.Keep{reply}

# A replay of w's reply that writes nothing.
def again(-S: Data, -P: Data, -R: Data, -E: Data, w: C.Step<S, P, R, E>) -> C.Step<S, P, R, E>:
  match w:
    case C.Write{s, C.Record{q, o, t}, reply, es}:
      C.Keep{C.Replayed{o}}
    case C.Keep{reply}:
      C.Keep{reply}

# When eq is reflexive, a retry with the same payload after the first commit writes nothing,
# emits nothing, and replays the first outcome, at any later time.
law retry_replays:
  for ~S: Data
  for ~P: Data
  for ~R: Data
  for ~E: Data
  for ~eq: P -> P -> Bool
  for ~refl: @x: P -> {eq(x, x) == True{} : Bool}
  for ~decide: S -> P -> C.Decision<S, R, E>
  for +s: S
  for +p: P
  for at: U32
  for later: U32
  {retried(~S, ~P, ~R, ~E, ~eq, ~decide, C.step(~S, ~P, ~R, ~E, ~eq, ~decide, None{}, s, p, at), p, later)
   == again(S, P, R, E, C.step(~S, ~P, ~R, ~E, ~eq, ~decide, None{}, s, p, at)) : C.Step<S, P, R, E>}
