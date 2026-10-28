# Packed F32 arrays: get, set, slice, concat, map, fold, zip, dot, sum, max, and little- or big-endian Bytes and files. Source: https://github.com/paymog/bend-kit/tree/main/f32array
import Base
import bend-kit-bytes@0.3.3.0/bytes.bend as Bytes
import bend-kit-files@0.3.0.0/files.bend as Files

# buf has the fewest 2^d slots that hold len, and every slot at or past len is +0.0.
type F32Array is Type:
  F32Array{len: U32, buf: Array<F32>}

def of_bits(x: U32) -> F32:
  match x:
    case U32{w}:
      F32{w}

def to_bits(x: F32) -> U32:
  match x:
    case F32{w}:
      U32{w}

def of_bits.be(x: U32) -> F32:
  +y = x
  of_bits(Bytes.bswap(y))

def to_bits.be(x: F32) -> U32:
  Bytes.bswap(to_bits(x))

def alloc(+n: U32) -> Array<F32>:
  Array.new(F32, Bytes.depth(n), 0.0)

# n zeros.
def new(+n: U32) -> F32Array:
  F32Array{n, alloc(n)}

def length(a: F32Array) -> F32Array & U32:
  F32Array{+len, buf} = a
  (F32Array{len, buf}, len)

def get.some(+len: U32, r: Array<F32> & F32) -> F32Array & Maybe<&2, F32>:
  (a, v) = r
  (F32Array{len, a}, Some{v})

def get.if(ok: Bool, +len: U32, buf: Array<F32>, +i: U32) -> F32Array & Maybe<&2, F32>:
  match ok:
    case True{}:
      get.some(len, Array.get(F32, buf, i))
    case False{}:
      (F32Array{len, buf}, None{})

# Element i, or None when i >= len.
def get(a: F32Array, +i: U32) -> F32Array & Maybe<&2, F32>:
  F32Array{+len, buf} = a
  get.if(U32.is_lt(i, len), len, buf, i)

def set.if(ok: Bool, +len: U32, buf: Array<F32>, +i: U32, v: F32) -> F32Array:
  match ok:
    case True{}:
      F32Array{len, Array.set(F32, buf, i, v)}
    case False{}:
      F32Array{len, buf}

# Element i becomes v. Nothing changes when i >= len.
def set(a: F32Array, +i: U32, v: F32) -> F32Array:
  F32Array{+len, buf} = a
  set.if(U32.is_lt(i, len), len, buf, i, v)

def count(xs: List<&2, F32>, +n: U32) -> U32:
  match xs:
    case Nil{}:
      n
    case Con{h, t}:
      count(t, (n + 1 : U32))

def from_list.go(xs: List<&2, F32>, a: Array<F32>, +i: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      a
    case Con{h, t}:
      from_list.go(t, Array.set(F32, a, i, h), (i + 1 : U32))

def from_list(+xs: List<&2, F32>) -> F32Array:
  +n = count(xs, 0)
  F32Array{n, from_list.go(xs, alloc(n), 0)}

# r holds element i; the list is built from the last element back.
def to_list.go(n: Nat, r: Array<F32> & F32, +i: U32, acc: List<&2, F32>) -> List<&2, F32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      (a, v) = r
      to_list.go(p, Array.get(F32, a, (i - 1 : U32)), (i - 1 : U32), Con{v, acc})

def to_list(a: F32Array) -> List<&2, F32>:
  F32Array{+len, buf} = a
  to_list.go(U32.to_nat(len), Array.get(F32, buf, (len - 1 : U32)), (len - 1 : U32), Nil{})

# n elements from src[s..] to dst[d..]; r holds src[s].
def copy.go(n: Nat, r: Array<F32> & F32, dst: Array<F32>, +s: U32, +d: U32) -> Array<F32> & Array<F32>:
  match n:
    case 0n:
      (a, v) = r
      (a, dst)
    case 1n+p:
      (a, v) = r
      copy.go(p, Array.get(F32, a, (s + 1 : U32)), Array.set(F32, dst, d, v), (s + 1 : U32), (d + 1 : U32))

def copy(+m: U32, src: Array<F32>, dst: Array<F32>, +s: U32, +d: U32) -> Array<F32> & Array<F32>:
  copy.go(U32.to_nat(m), Array.get(F32, src, s), dst, s, d)

def slice.fin(+len: U32, +m: U32, r: Array<F32> & Array<F32>) -> F32Array & F32Array:
  (a, c) = r
  (F32Array{len, a}, F32Array{m, c})

# The array back, and a copy of up to n elements from start. Both ends are clamped to len.
def slice(a: F32Array, +start: U32, +n: U32) -> F32Array & F32Array:
  F32Array{+len, buf} = a
  +s = U32.min(start, len)
  +m = U32.min(n, (len - s : U32))
  slice.fin(len, m, copy(m, buf, alloc(m), s, 0))

def concat.total.con(x: F32Array, r: List<&1, F32Array> & U32) -> List<&1, F32Array> & U32:
  (t, n) = r
  (Con{x, t}, n)

def concat.total(xs: List<&1, F32Array>, +n: U32) -> List<&1, F32Array> & U32:
  match xs:
    case Nil{}:
      (Nil{}, n)
    case Con{F32Array{+len, buf}, t}:
      concat.total.con(F32Array{len, buf}, concat.total(t, (n + len : U32)))

def snd(r: Array<F32> & Array<F32>) -> Array<F32>:
  (a, b) = r
  b

def concat.go(xs: List<&1, F32Array>, out: Array<F32>, +at: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      out
    case Con{F32Array{+len, buf}, t}:
      concat.go(t, snd(copy(len, buf, out, 0, at)), (at + len : U32))

def concat.of(r: List<&1, F32Array> & U32) -> F32Array:
  (xs, +n) = r
  F32Array{n, concat.go(xs, alloc(n), 0)}

# The pieces in order, in one new array.
def concat(xs: List<&1, F32Array>) -> F32Array:
  concat.of(concat.total(xs, 0))

# r holds element i. Slots at or past len are not touched, so they stay +0.0.
def map.go(~f: F32 -> F32, n: Nat, r: Array<F32> & F32, +i: U32) -> Array<F32>:
  match n:
    case 0n:
      (a, v) = r
      a
    case 1n+p:
      (a, v) = r
      map.go(~f, p, Array.get(F32, Array.set(F32, a, i, f(v)), (i + 1 : U32)), (i + 1 : U32))

# f on each element, in place.
def map(~f: F32 -> F32, a: F32Array) -> F32Array:
  F32Array{+len, buf} = a
  F32Array{len, map.go(~f, U32.to_nat(len), Array.get(F32, buf, 0), 0)}

def fold.go(~A: Data, ~f: A -> F32 -> A, n: Nat, r: Array<F32> & F32, +i: U32, acc: A) -> Array<F32> & A:
  match n:
    case 0n:
      (a, v) = r
      (a, acc)
    case 1n+p:
      (a, v) = r
      fold.go(~A, ~f, p, Array.get(F32, a, (i + 1 : U32)), (i + 1 : U32), f(acc, v))

def fold.fin(-A: Data, +len: U32, r: Array<F32> & A) -> F32Array & A:
  (a, x) = r
  (F32Array{len, a}, x)

# f(...f(f(init, a[0]), a[1])..., a[len-1]), left to right.
def fold(~A: Data, ~f: A -> F32 -> A, a: F32Array, init: A) -> F32Array & A:
  F32Array{+len, buf} = a
  fold.fin(A, len, fold.go(~A, ~f, U32.to_nat(len), Array.get(F32, buf, 0), 0, init))

# r holds a[i] and s holds b[i]; f(a[i], b[i]) goes into a.
def zip.go(~f: F32 -> F32 -> F32, n: Nat, r: Array<F32> & F32, s: Array<F32> & F32, +i: U32) -> Array<F32>:
  match n:
    case 0n:
      (a, x) = r
      (b, y) = s
      a
    case 1n+p:
      (a, x) = r
      (b, y) = s
      +j = (i + 1 : U32)
      zip.go(~f, p, Array.get(F32, Array.set(F32, a, i, f(x, y)), j), Array.get(F32, b, j), j)

def zip.if(~f: F32 -> F32 -> F32, same: Bool, +len: U32, xa: Array<F32>, ya: Array<F32>) -> Maybe<&1, F32Array>:
  match same:
    case True{}:
      Some{F32Array{len, zip.go(~f, U32.to_nat(len), Array.get(F32, xa, 0), Array.get(F32, ya, 0), 0)}}
    case False{}:
      None{}

# f(a[i], b[i]) for each i, written into a's buffer. None when the lengths differ.
def zip_with(~f: F32 -> F32 -> F32, a: F32Array, b: F32Array) -> Maybe<&1, F32Array>:
  F32Array{+la, xa} = a
  F32Array{+lb, ya} = b
  zip.if(~f, U32.is_eq(la, lb), la, xa, ya)

def add2(x: F32, y: F32) -> F32:
  (x + y : F32)

def mul2(x: F32, y: F32) -> F32:
  (x * y : F32)

# a[i] + b[i]. None when the lengths differ.
def add(a: F32Array, b: F32Array) -> Maybe<&1, F32Array>:
  zip_with(~add2, a, b)

# a[i] * b[i]. None when the lengths differ.
def mul(a: F32Array, b: F32Array) -> Maybe<&1, F32Array>:
  zip_with(~mul2, a, b)

# The sum, added left to right from +0.0.
# ponytail: one sequential pass, so error grows with len; a pairwise fork-join sum fixes accuracy and uses every core.
def sum(a: F32Array) -> F32Array & F32:
  fold(~F32, ~add2, a, 0.0)

def max.some(r: F32Array & F32) -> F32Array & Maybe<&2, F32>:
  (a, x) = r
  (a, Some{x})

def max.of(r: F32Array & Maybe<&2, F32>) -> F32Array & Maybe<&2, F32>:
  (a, m) = r
  match m:
    case None{}:
      (a, None{})
    case Some{x}:
      max.some(fold(~F32, ~F32.max, a, x))

# The largest element by Base F32.max, or None when empty. A NaN is kept only when it comes first.
def max(a: F32Array) -> F32Array & Maybe<&2, F32>:
  max.of(get(a, 0))

def dot.go(n: Nat, r: Array<F32> & F32, s: Array<F32> & F32, +i: U32, acc: F32) -> Array<F32> & Array<F32> & F32:
  match n:
    case 0n:
      (a, x) = r
      (b, y) = s
      (a, b, acc)
    case 1n+p:
      (a, +x) = r
      (b, +y) = s
      +j = (i + 1 : U32)
      dot.go(p, Array.get(F32, a, j), Array.get(F32, b, j), j, (acc + x * y : F32))

def dot.fin(+la: U32, +lb: U32, r: Array<F32> & Array<F32> & F32) -> F32Array & F32Array & Maybe<&2, F32>:
  (a, b, x) = r
  (F32Array{la, a}, F32Array{lb, b}, Some{x})

def dot.if(same: Bool, +la: U32, xa: Array<F32>, +lb: U32, ya: Array<F32>) -> F32Array & F32Array & Maybe<&2, F32>:
  match same:
    case True{}:
      dot.fin(la, lb, dot.go(U32.to_nat(la), Array.get(F32, xa, 0), Array.get(F32, ya, 0), 0, 0.0))
    case False{}:
      (F32Array{la, xa}, F32Array{lb, ya}, None{})

# Both arrays back, and the sum of a[i] * b[i], added left to right. None when the lengths differ.
def dot(a: F32Array, b: F32Array) -> F32Array & F32Array & Maybe<&2, F32>:
  F32Array{+la, xa} = a
  F32Array{+lb, ya} = b
  dot.if(U32.is_eq(la, lb), la, xa, lb, ya)

# Bytes word k holds bytes 4k..4k+3 with byte 4k lowest, so an aligned buffer maps word for word.
def from_bytes.if(~f: U32 -> F32, aligned: Bool, +len: U32, buf: Array<U32>) -> Maybe<&1, F32Array>:
  match aligned:
    case True{}:
      Some{F32Array{(len >> 2n : U32), Array.map(~U32, ~F32, ~f, buf)}}
    case False{}:
      None{}

# Four bytes per element, least significant first. None when the length is not a multiple of 4.
def from_bytes.le(b: Bytes.Bytes) -> Maybe<&1, F32Array>:
  Bytes.Bytes{+len, buf} = b
  from_bytes.if(~of_bits, U32.is_eq((len .&. 3 : U32), 0), len, buf)

# Four bytes per element, most significant first. None when the length is not a multiple of 4.
def from_bytes.be(b: Bytes.Bytes) -> Maybe<&1, F32Array>:
  Bytes.Bytes{+len, buf} = b
  from_bytes.if(~of_bits.be, U32.is_eq((len .&. 3 : U32), 0), len, buf)

# Each element as four bytes, least significant first. len must be below 2^30.
def to_bytes.le(a: F32Array) -> Bytes.Bytes:
  F32Array{+len, buf} = a
  Bytes.Bytes{(len << 2n : U32), Array.map(~F32, ~U32, ~to_bits, buf)}

# Each element as four bytes, most significant first. len must be below 2^30.
def to_bytes.be(a: F32Array) -> Bytes.Bytes:
  F32Array{+len, buf} = a
  Bytes.Bytes{(len << 2n : U32), Array.map(~F32, ~U32, ~to_bits.be, buf)}

# A file read in progress: more bytes to read, or the final result.
type Read is Type:
  More{file: File, acc: Bytes.Bytes, left: U32}
  Stop{file: File, result: Result<&1, &1, U32 & String, Bytes.Bytes>}

def read.next(more: Bool, file: File, acc: Bytes.Bytes, +left: U32) -> Read:
  match more:
    case True{}:
      More{file, acc, left}
    case False{}:
      Stop{file, Done{acc}}

# A read of no bytes ends the loop early, so a file that shrank stops there.
def read.step(got: File & Result<&1, &1, U32 & String, Bytes.Bytes>, acc: Bytes.Bytes, +left: U32) -> Read:
  (file, r) = got
  match r:
    case Fail{e}:
      Stop{file, Fail{e}}
    case Done{Bytes.Bytes{+m, buf}}:
      +rest = (left - U32.min(m, left) : U32)
      read.next(Bool.and(U32.is_ne(m, 0), U32.is_ne(rest, 0)), file, Bytes.append(acc, Bytes.Bytes{m, buf}), rest)

# Each pass reads at least one byte or stops, so left + 1 passes are enough.
def read.loop(n: Nat, st: Read) -> IO(File & Result<&1, &1, U32 & String, Bytes.Bytes>):
  match n:
    case 0n:
      match st:
        case More{file, acc, left}:
          IO.pure(File & Result<&1, &1, U32 & String, Bytes.Bytes>, (file, Done{acc}))
        case Stop{file, result}:
          IO.pure(File & Result<&1, &1, U32 & String, Bytes.Bytes>, (file, result))
    case 1n+p:
      match st:
        case More{file, acc, +left}:
          do IO<File & Result<&1, &1, U32 & String, Bytes.Bytes>>:
            got : File & Result<&1, &1, U32 & String, Bytes.Bytes> <- Files.read_bytes(file, U32.min(left, 1048576))
            read.loop(p, read.step(got, acc, left))
        case Stop{file, result}:
          IO.pure(File & Result<&1, &1, U32 & String, Bytes.Bytes>, (file, result))

def read.sized(sz: File & Result<&1, &1, U32 & String, U32>) -> IO(File & Result<&1, &1, U32 & String, Bytes.Bytes>):
  (file, r) = sz
  match r:
    case Fail{e}:
      IO.pure(File & Result<&1, &1, U32 & String, Bytes.Bytes>, (file, Fail{e}))
    case Done{+n}:
      read.loop(1n+U32.to_nat(n), read.next(U32.is_ne(n, 0), file, Bytes.new(0), n))

def read.decode(m: Maybe<&1, F32Array>) -> Result<&1, &1, U32 & String, F32Array>:
  match m:
    case None{}:
      Fail{(22, "f32array: the file size is not a multiple of 4")}
    case Some{a}:
      Done{a}

def read.fin(~f: Bytes.Bytes -> Maybe<&1, F32Array>, got: File & Result<&1, &1, U32 & String, Bytes.Bytes>) -> File & Result<&1, &1, U32 & String, F32Array>:
  (file, r) = got
  match r:
    case Fail{e}:
      (file, Fail{e})
    case Done{b}:
      (file, read.decode(f(b)))

def read.with(~f: Bytes.Bytes -> Maybe<&1, F32Array>, file: File) -> IO(File & Result<&1, &1, U32 & String, F32Array>):
  do IO<File & Result<&1, &1, U32 & String, F32Array>>:
    sz : File & Result<&1, &1, U32 & String, U32> <- File.size(file)
    got : File & Result<&1, &1, U32 & String, Bytes.Bytes> <- read.sized(sz)
    return read.fin(~f, got)

# The rest of an open file, four little-endian bytes per element. Fails EINVAL when its size is not a multiple of 4.
def read.le(file: File) -> IO(File & Result<&1, &1, U32 & String, F32Array>):
  read.with(~from_bytes.le, file)

# The rest of an open file, four big-endian bytes per element. Fails EINVAL when its size is not a multiple of 4.
def read.be(file: File) -> IO(File & Result<&1, &1, U32 & String, F32Array>):
  read.with(~from_bytes.be, file)
