/-
  UnitTestsFence.lean — checks of Crypto/Sha256 (FIPS 180-4 / RFC 4231
  vectors) and StateMachine/HandoverFence (the break-glass of a halted
  handover, design addenda 6–10). Called from UnitTests.run.
-/
import FlareOperator.Crypto.Sha256
import FlareOperator.StateMachine.HandoverFence

namespace FlareOperator.UnitTestsFence

open FlareOperator.Crypto
open FlareOperator.HandoverFence

private def rep (b : UInt8) (n : Nat) : ByteArray := ⟨(List.replicate n b).toArray⟩

def results : List (String × Bool) := Id.run do
  let mut r : List (String × Bool) := []
  r := r ++ [("sha256: the FIPS 180-4 vectors (empty, abc, the 448-bit message, a million a)",
              toHex (sha256 "".toUTF8) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                && toHex (sha256 "abc".toUTF8) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                && toHex (sha256 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toUTF8)
                    == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
                && toHex (sha256 (rep 0x61 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")]
  r := r ++ [("hmac-sha256: RFC 4231 cases 1, 2 and 6 (a key longer than the block)",
              toHex (hmacSha256 (rep 0x0b 20) "Hi There".toUTF8) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
                && toHex (hmacSha256 "Jefe".toUTF8 "what do ya want for nothing?".toUTF8) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
                && toHex (hmacSha256 (rep 0xaa 131) "Test Using Larger Than Block-Size Key - Hash Key First".toUTF8)
                    == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")]
  r := r ++ [("hex: round trip; odd length or a non-hex digit is none; constEq",
              (fromHex? "00ff10Ab").map toHex == some "00ff10ab" && (fromHex? "abc").isNone && (fromHex? "zz").isNone
                && constEq "abc" "abc" && !constEq "abc" "abd" && !constEq "abc" "ab")]
  let key := "k3y-for-tests".toUTF8
  let value := "TICKET-9/p0-a1-1100/u1/b1/c1"
  let some v := parseValue? value | return r ++ [("fence: the value parses", false)]
  let rcpt := receiptFor key value v "rev-1" "alice@example.com/sre" "uid-a"
  r := r ++ [("fence: the value is approval/hid/uid/boot/copy (5 non-empty fields); its binding is uid|boot|copy",
              v.binding == "u1|b1|c1" && v.approvalId == "TICKET-9" && v.hid == "p0-a1-1100"
                && parseValue? "a/b/c/d" == none && parseValue? "a//c/d/e" == none && parseValue? "a/b/c/d/e/f" == none)]
  r := r ++ [("fence: a receipt the webhook wrote verifies (a / in the username is escaped); another key, value, hid or a forged MAC does not",
              (parseReceipt? rcpt).any (receiptValid key value v ·)
                && (parseReceipt? rcpt).any (·.username == "alice@example.com/sre")
                && !(parseReceipt? rcpt).any (receiptValid "other".toUTF8 value v ·)
                && !(parseReceipt? rcpt).any (receiptValid key "TICKET-9/p0-a1-1100/u1/b2/c1" { v with bootId := "b2" } ·)
                && !(parseReceipt? rcpt).any (fun x => receiptValid key value v { x with mac := String.mk (List.replicate 64 'a') })
                && !(parseReceipt? rcpt).any (fun x => receiptValid key value v { x with username := "mallory" })
                && !(parseReceipt? rcpt).any (receiptValid ByteArray.empty value v ·))]
  let sar := (sarJson "ns1" "c1" "alice" "uid-a" ["sre"]).compress
  r := r ++ [("fence: the SubjectAccessReview names group flare.gree.net, verb break-glass, flareclusters/handover-fence, the namespace and name (addendum 10)",
              (sar.splitOn "\"group\":\"flare.gree.net\"").length == 2 && (sar.splitOn "\"verb\":\"break-glass\"").length == 2
                && (sar.splitOn "\"resource\":\"flareclusters\"").length == 2 && (sar.splitOn "\"subresource\":\"handover-fence\"").length == 2
                && (sar.splitOn "\"namespace\":\"ns1\"").length == 2 && (sar.splitOn "\"name\":\"c1\"").length == 2
                && sarAllowed? "{\"status\":{\"allowed\":true}}" == some true && sarAllowed? "{\"status\":{\"allowed\":false}}" == some false
                && sarAllowed? "{\"status\":{}}" == none && sarAllowed? "nope" == none)]
  r := r ++ [("fence: the webhook asks only when the value is added or changed; a bad value is refused; a receipt touched without a new value is put back or removed",
              mutation none (some value) none none == .authorize v
                && mutation (some "x/x/x/x/x") (some value) none none == .authorize v
                && mutation (some value) (some value) (some rcpt) (some rcpt) == .none
                && mutation (some value) (some value) (some rcpt) (some "forged") == .restoreReceipt (some rcpt)
                && mutation none none none (some "forged") == .restoreReceipt none
                && mutation none none none none == .none
                && (match mutation none (some "bad") none none with | .invalid _ => true | _ => false))]
  let ok? := fun (x : Except String FencedBy) => match x with | .ok _ => true | .error _ => false
  let good := consume key "p0-a1-1100" "u1|b1|c1" false [] value (some rcpt) "t"
  r := r ++ [("fence: consumed once — the right hid, binding and webhook receipt; refused: already fenced, another hid, another boot id, a used approval id, no receipt (did not pass the webhook), a forged receipt, no key",
              (match good with | .ok f => f.username == "alice@example.com/sre" && f.reviewUid == "rev-1" && f.value == value | .error _ => false)
                && !ok? (consume key "p0-a1-1100" "u1|b1|c1" true [] value (some rcpt) "t")
                && !ok? (consume key "p0-a2-2000" "u1|b1|c1" false [] value (some rcpt) "t")
                && !ok? (consume key "p0-a1-1100" "u1|b9|c1" false [] value (some rcpt) "t")
                && !ok? (consume key "p0-a1-1100" "u1|b1|c1" false ["TICKET-9"] value (some rcpt) "t")
                && !ok? (consume key "p0-a1-1100" "u1|b1|c1" false [] value none "t")
                && !ok? (consume key "p0-a1-1100" "u1|b1|c1" false [] value (some "TICKET-9/p0-a1-1100/r/u/uu/00") "t")
                && !ok? (consume ByteArray.empty "p0-a1-1100" "u1|b1|c1" false [] value (some rcpt) "t")
                && !ok? (consume key "" "u1|b1|c1" false [] value (some rcpt) "t"))]
  let addP := (annotationPatch receiptAnnotation (some "x") false).compress
  let repP := (annotationPatch receiptAnnotation (some "x") true).compress
  let remP := (annotationPatch receiptAnnotation none true).compress
  let has := fun (h n : String) => (h.splitOn n).length > 1
  r := r ++ [("fence: the annotation patch escapes / as ~1 (add, replace, remove)",
              has addP "\"path\":\"/metadata/annotations/flare.gree.net~1handover-fenced-receipt\"" && has addP "\"op\":\"add\"" && has addP "\"value\":\"x\""
                && has repP "\"op\":\"replace\"" && has remP "\"op\":\"remove\"" && !has remP "\"value\"")]
  return r

end FlareOperator.UnitTestsFence
