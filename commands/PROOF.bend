import Base
import ./commands.bend as C
import ./LAWS.bend as Laws

def Laws.duplicate_replays(S, P, R, E, eq, decide, q, o, t, p, same, s, at):
  %Equal.sym(Bool, eq(q, p), True{}, same) : {C.Keep{C.replayed(R, _, o)} == C.Keep{C.Replayed{o}} : C.Step<S, P, R, E>}
  {==}

def Laws.conflict_rejected(S, P, R, E, eq, decide, q, o, t, p, differ, s, at):
  %Equal.sym(Bool, eq(q, p), False{}, differ) : {C.Keep{C.replayed(R, _, o)} == C.Keep{C.Conflict{}} : C.Step<S, P, R, E>}
  {==}

def Laws.accept_recorded(S, P, R, E, eq, decide, s, p, at, s2, r, es, e):
  %Equal.sym(C.Decision<S, R, E>, decide(s, p), C.Accept{s2, r, es}, e) : {C.decided(S, P, R, E, _, s, p, at) == C.Write{s2, C.Record{p, C.Accepted{r}, at}, C.Fresh{C.Accepted{r}}, es} : C.Step<S, P, R, E>}
  {==}

def Laws.refuse_keeps_state(S, P, R, E, eq, decide, s, p, at, r, e):
  %Equal.sym(C.Decision<S, R, E>, decide(s, p), C.Refuse{r}, e) : {C.decided(S, P, R, E, _, s, p, at) == C.Write{s, C.Record{p, C.Refused{r}, at}, C.Fresh{C.Refused{r}}, Nil{}} : C.Step<S, P, R, E>}
  {==}

# retry_replays for any decision d, not only decide(s, p).
def retry.go(
  ~S: Data, ~P: Data, ~R: Data, ~E: Data, ~eq: P -> P -> Bool, ~refl: @x: P -> {eq(x, x) == True{} : Bool},
  ~decide: S -> P -> C.Decision<S, R, E>, d: C.Decision<S, R, E>, +s: S, +p: P, at: U32, later: U32
) -> {Laws.retried(~S, ~P, ~R, ~E, ~eq, ~decide, C.decided(S, P, R, E, d, s, p, at), p, later) == Laws.again(S, P, R, E, C.decided(S, P, R, E, d, s, p, at)) : C.Step<S, P, R, E>}:
  match d:
    case C.Accept{s2, r, es}:
      %Equal.sym(Bool, eq(p, p), True{}, refl(p)) : {C.Keep{C.replayed(R, _, C.Accepted{r})} == C.Keep{C.Replayed{C.Accepted{r}}} : C.Step<S, P, R, E>}
      {==}
    case C.Refuse{r}:
      %Equal.sym(Bool, eq(p, p), True{}, refl(p)) : {C.Keep{C.replayed(R, _, C.Refused{r})} == C.Keep{C.Replayed{C.Refused{r}}} : C.Step<S, P, R, E>}
      {==}

def Laws.retry_replays(S, P, R, E, eq, refl, decide, s, p, at, later):
  retry.go(~S, ~P, ~R, ~E, ~eq, ~refl, ~decide, decide(s, p), s, p, at, later)
