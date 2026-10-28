import Base
import bend-kit-bytes@0.3.3.0/bytes.bend as Bytes
import ./f32array.bend as A

def octets(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case Con{h, t}:
      SCon{Chr{h}, octets(t)}

def of(+xs: List<&2, F32>) -> A.F32Array:
  A.from_list(xs)

def list(a: A.F32Array) -> List<&2, F32>:
  A.to_list(a)

def count(r: A.F32Array & U32) -> U32:
  (a, n) = r
  n

def len(a: A.F32Array) -> U32:
  count(A.length(a))

def kept(r: A.F32Array & A.F32Array) -> List<&2, F32>:
  (a, b) = r
  list(a)

def piece(r: A.F32Array & A.F32Array) -> List<&2, F32>:
  (a, b) = r
  list(b)

def lists(m: Maybe<&1, A.F32Array>) -> Maybe<&2, List<&2, F32>>:
  match m:
    case None{}:
      None{}
    case Some{a}:
      Some{list(a)}

def folded(r: A.F32Array & List<&2, F32>) -> List<&2, F32>:
  (a, xs) = r
  xs

def value(r: A.F32Array & Maybe<&2, F32>) -> Maybe<&2, F32>:
  (a, x) = r
  x

def at(a: A.F32Array, +i: U32) -> Maybe<&2, F32>:
  value(A.get(a, i))

def total(r: A.F32Array & F32) -> F32:
  (a, x) = r
  x

def product(r: A.F32Array & A.F32Array & Maybe<&2, F32>) -> Maybe<&2, F32>:
  (a, b, x) = r
  x

def wire(b: Bytes.Bytes) -> String:
  Bytes.to_string(b)

def neg2() -> F32:
  A.of_bits(3221225472)

def neg1() -> F32:
  A.of_bits(3212836864)

def neghalf() -> F32:
  A.of_bits(3204448256)

# The sign bit flipped, by bits alone: the checker does not run F32 arithmetic.
def flip(x: F32) -> F32:
  A.of_bits((A.to_bits(x) .^. 2147483648 : U32))

def keep(x: F32, y: F32) -> F32:
  y

def push(xs: List<&2, F32>, x: F32) -> List<&2, F32>:
  Con{x, xs}

law new_zeros:
  {list(A.new(3)) == [0.0, 0.0, 0.0] : List<&2, F32>}

law new_empty:
  {list(A.new(0)) == [] : List<&2, F32>}

law length_of:
  {len(of([1.0, 2.5, neg2()])) == 3 : U32}

law list_roundtrip:
  {list(of([1.0, 2.5, neg2(), 0.5, 3.0])) == [1.0, 2.5, neg2(), 0.5, 3.0] : List<&2, F32>}

law get_in:
  {at(of([1.0, 2.5, neg2()]), 1) == Some{2.5} : Maybe<&2, F32>}

law get_past_len:
  {at(of([1.0, 2.5, neg2()]), 3) == None{} : Maybe<&2, F32>}

law get_after_set:
  {at(A.set(of([1.0, 2.5, neg2()]), 2, 0.5), 2) == Some{0.5} : Maybe<&2, F32>}

law set_keeps_others:
  {list(A.set(of([1.0, 2.5, neg2()]), 0, 0.5)) == [0.5, 2.5, neg2()] : List<&2, F32>}

law set_past_len:
  {list(A.set(of([1.0, 2.5, neg2()]), 3, 0.5)) == [1.0, 2.5, neg2()] : List<&2, F32>}

law slice_middle:
  {piece(A.slice(of([1.0, 2.5, neg2(), 0.5, 3.0]), 1, 3)) == [2.5, neg2(), 0.5] : List<&2, F32>}

law slice_keeps_source:
  {kept(A.slice(of([1.0, 2.5, neg2()]), 1, 1)) == [1.0, 2.5, neg2()] : List<&2, F32>}

law slice_clamps_count:
  {piece(A.slice(of([1.0, 2.5, neg2()]), 1, 9)) == [2.5, neg2()] : List<&2, F32>}

law slice_clamps_start:
  {piece(A.slice(of([1.0, 2.5, neg2()]), 7, 2)) == [] : List<&2, F32>}

law concat_pieces:
  {list(A.concat([of([1.0, 2.5]), of([]), of([neg2(), 0.5, 3.0])])) == [1.0, 2.5, neg2(), 0.5, 3.0] : List<&2, F32>}

law concat_none:
  {list(A.concat([])) == [] : List<&2, F32>}

law map_each:
  {list(A.map(~flip, of([1.0, neg2(), 0.5]))) == [neg1(), 2.0, neghalf()] : List<&2, F32>}

# The slot past len stays +0.0, so the bytes end where the elements end.
law map_keeps_tail:
  {wire(A.to_bytes.le(A.map(~flip, A.new(3)))) == octets([0, 0, 0, 128, 0, 0, 0, 128, 0, 0, 0, 128]) : String}

law fold_order:
  {folded(A.fold(~List<&2, F32>, ~push, of([1.0, 2.5, neg2()]), [])) == [neg2(), 2.5, 1.0] : List<&2, F32>}

law fold_empty:
  {folded(A.fold(~List<&2, F32>, ~push, of([]), [0.5])) == [0.5] : List<&2, F32>}

law zip_pairs:
  {lists(A.zip_with(~keep, of([1.0, 2.5]), of([neg2(), 0.5]))) == Some{[neg2(), 0.5]} : Maybe<&2, List<&2, F32>>}

law zip_mismatch:
  {lists(A.zip_with(~keep, of([1.0, 2.5]), of([neg2()]))) == None{} : Maybe<&2, List<&2, F32>>}

law add_mismatch:
  {lists(A.add(of([1.0]), of([]))) == None{} : Maybe<&2, List<&2, F32>>}

law mul_mismatch:
  {lists(A.mul(of([]), of([1.0]))) == None{} : Maybe<&2, List<&2, F32>>}

law sum_empty:
  {total(A.sum(of([]))) == 0.0 : F32}

law max_empty:
  {value(A.max(of([]))) == None{} : Maybe<&2, F32>}

law dot_empty:
  {product(A.dot(of([]), of([]))) == Some{0.0} : Maybe<&2, F32>}

law dot_mismatch:
  {product(A.dot(of([1.0]), of([1.0, 2.5]))) == None{} : Maybe<&2, F32>}

# 1.0 is 0x3F800000 and neg2() is 0xC0000000.
law to_bytes_le:
  {wire(A.to_bytes.le(of([1.0, neg2()]))) == octets([0, 0, 128, 63, 0, 0, 0, 192]) : String}

law to_bytes_be:
  {wire(A.to_bytes.be(of([1.0, neg2()]))) == octets([63, 128, 0, 0, 192, 0, 0, 0]) : String}

law from_bytes_le:
  {lists(A.from_bytes.le(Bytes.from_string(octets([0, 0, 128, 63, 0, 0, 0, 192])))) == Some{[1.0, neg2()]} : Maybe<&2, List<&2, F32>>}

law from_bytes_be:
  {lists(A.from_bytes.be(Bytes.from_string(octets([63, 128, 0, 0, 192, 0, 0, 0])))) == Some{[1.0, neg2()]} : Maybe<&2, List<&2, F32>>}

law from_bytes_unaligned:
  {lists(A.from_bytes.le(Bytes.from_string(octets([0, 0, 128, 63, 0])))) == None{} : Maybe<&2, List<&2, F32>>}

law from_bytes_empty:
  {lists(A.from_bytes.le(Bytes.new(0))) == Some{[]} : Maybe<&2, List<&2, F32>>}

law bytes_roundtrip_le:
  {lists(A.from_bytes.le(A.to_bytes.le(of([1.0, 2.5, neg2(), 0.5, 3.0])))) == Some{[1.0, 2.5, neg2(), 0.5, 3.0]} : Maybe<&2, List<&2, F32>>}

law bytes_roundtrip_be:
  {lists(A.from_bytes.be(A.to_bytes.be(of([1.0, 2.5, neg2(), 0.5, 3.0])))) == Some{[1.0, 2.5, neg2(), 0.5, 3.0]} : Maybe<&2, List<&2, F32>>}
