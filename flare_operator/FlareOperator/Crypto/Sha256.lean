/-
  Crypto/Sha256.lean — SHA-256 (FIPS 180-4) and HMAC-SHA-256 (RFC 2104),
  pure. Used for the break-glass receipt of a handover fence
  (docs/design-handover-history-continuation.md addendum 8): the webhook
  computes it on every such admission, so no subprocess and no library.
  Checked against the FIPS / RFC 4231 test vectors in the unit tests.
-/
namespace FlareOperator.Crypto

private def k : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

private def h0 : Array UInt32 := #[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

@[inline] private def rotr (x : UInt32) (n : UInt32) : UInt32 := (x >>> n) ||| (x <<< (32 - n))

/-- The message padded to a multiple of 64 bytes (0x80, zeros, the bit length big-endian). -/
private def pad (m : ByteArray) : ByteArray := Id.run do
  let bits : UInt64 := m.size.toUInt64 * 8
  let mut b := m.push 0x80
  while b.size % 64 != 56 do
    b := b.push 0
  for i in [0:8] do
    b := b.push ((bits >>> ((7 - i).toUInt64 * 8)) &&& 0xff).toUInt8
  return b

private def word (b : ByteArray) (i : Nat) : UInt32 :=
  (b.get! i).toUInt32 <<< 24 ||| (b.get! (i+1)).toUInt32 <<< 16 ||| (b.get! (i+2)).toUInt32 <<< 8 ||| (b.get! (i+3)).toUInt32

private def block (h : Array UInt32) (b : ByteArray) (off : Nat) : Array UInt32 := Id.run do
  let mut w : Array UInt32 := Array.mkEmpty 64
  for t in [0:16] do
    w := w.push (word b (off + 4 * t))
  for t in [16:64] do
    let x := w[t-15]!
    let y := w[t-2]!
    let s0 := rotr x 7 ^^^ rotr x 18 ^^^ (x >>> 3)
    let s1 := rotr y 17 ^^^ rotr y 19 ^^^ (y >>> 10)
    w := w.push (w[t-16]! + s0 + w[t-7]! + s1)
  let mut a := h[0]!
  let mut bb := h[1]!
  let mut c := h[2]!
  let mut d := h[3]!
  let mut e := h[4]!
  let mut f := h[5]!
  let mut g := h[6]!
  let mut hh := h[7]!
  for t in [0:64] do
    let S1 := rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25
    let ch := (e &&& f) ^^^ ((~~~e) &&& g)
    let t1 := hh + S1 + ch + k[t]! + w[t]!
    let S0 := rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22
    let mj := (a &&& bb) ^^^ (a &&& c) ^^^ (bb &&& c)
    let t2 := S0 + mj
    hh := g
    g := f
    f := e
    e := d + t1
    d := c
    c := bb
    bb := a
    a := t1 + t2
  return #[h[0]! + a, h[1]! + bb, h[2]! + c, h[3]! + d, h[4]! + e, h[5]! + f, h[6]! + g, h[7]! + hh]

/-- SHA-256 of `m` (32 bytes). -/
def sha256 (m : ByteArray) : ByteArray := Id.run do
  let p := pad m
  let mut h := h0
  for i in [0:p.size / 64] do
    h := block h p (64 * i)
  let mut out := ByteArray.empty
  for x in h do
    out := out.push (x >>> 24).toUInt8 |>.push (x >>> 16).toUInt8 |>.push (x >>> 8).toUInt8 |>.push x.toUInt8
  return out

/-- HMAC-SHA-256 (RFC 2104, block 64 bytes). -/
def hmacSha256 (key msg : ByteArray) : ByteArray := Id.run do
  let k0 := if key.size > 64 then sha256 key else key
  let mut ipad := ByteArray.empty
  let mut opad := ByteArray.empty
  for i in [0:64] do
    let b := if i < k0.size then k0.get! i else 0
    ipad := ipad.push (b ^^^ 0x36)
    opad := opad.push (b ^^^ 0x5c)
  return sha256 (opad ++ sha256 (ipad ++ msg))

private def hexDigit (n : UInt8) : Char :=
  if n < 10 then Char.ofNat (48 + n.toNat) else Char.ofNat (87 + n.toNat)

/-- Lower-case hex. -/
def toHex (b : ByteArray) : String :=
  b.foldl (fun s x => (s.push (hexDigit (x >>> 4))).push (hexDigit (x &&& 0xf))) ""

/-- Bytes of a hex string (`none` = odd length or not hex). -/
def fromHex? (s : String) : Option ByteArray := do
  let cs := s.toList
  if cs.length % 2 != 0 then none
  let v := fun (c : Char) =>
    if '0' ≤ c && c ≤ '9' then some (c.toNat - 48)
    else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
    else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
    else none
  let rec go : List Char → ByteArray → Option ByteArray
    | a :: b :: rest, acc => do
      let x ← v a
      let y ← v b
      go rest (acc.push (x * 16 + y).toUInt8)
    | [], acc => some acc
    | _, _ => none
  go cs ByteArray.empty

/-- Constant-time comparison of two equal-length strings (a mismatch in
    length is false at once: the lengths are public). -/
def constEq (a b : String) : Bool :=
  a.length == b.length &&
    (a.toList.zip b.toList).foldl (fun acc (x, y) => acc ||| (x.toNat ^^^ y.toNat)) 0 == 0

end FlareOperator.Crypto
