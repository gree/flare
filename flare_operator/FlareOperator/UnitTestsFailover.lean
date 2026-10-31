/-
  UnitTestsFailover.lean — checks of StateMachine/FailoverOrder.lean and its
  use by the masterless refill (K8sReconciler.promoteMasterlessPartition):
  among the followers of the last master the largest applied position is
  promoted. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.FailoverOrder
import FlareOperator.StateMachine.K8sReconciler

namespace FlareOperator.UnitTestsFailover

open FlareOperator.K8s
open FlareOperator.FailoverOrder

private def cp (k : String) (ep : Option String) (n : Option Nat) : Copy :=
  { key := k, epoch := ep, applied := n }

private def node (name : String) (role : FlareRole) (st : FlareState) (part : Int) : FlareNode :=
  { serverName := name, serverPort := 12121, role := role, state := st, partition := part }

/-- partition 0 has lost its master; three Active slaves a, b, c in map order. -/
private def masterless : FlareClusterState :=
  ({ nodeMap := [("a", node "a" .Slave .Active 0), ("b", node "b" .Slave .Active 0),
                 ("c", node "c" .Slave .Active 0)],
     nodeMapVersion := 5 } : FlareClusterState).rebuildPartitionMap

private def masterOf (s : FlareClusterState) : Option String :=
  (s.nodeMap.find? (fun kv => kv.2.role == FlareRole.Master)).map (·.1)

private def refill (ranked : List String) (blocked : List String := []) (standby : List String := [])
    (prefer : Option String := none) : Option String :=
  masterOf (K8sReconciler.promoteMasterlessPartition masterless 0 ["a", "b", "c"] standby ["a", "b", "c"]
    [] false [] blocked prefer ranked)

def results : List (String × Bool) := Id.run do
  let ep := some "2:e"
  let mut r : List (String × Bool) := []
  r := r ++ [("failover order: followers of the last master, largest applied position first",
    (order ep [cp "a" ep (some 10), cp "b" ep (some 30), cp "c" ep (some 20)]) ==
      { ranked := ["b", "c", "a"], proof := .proven })]
  r := r ++ [("failover order: another source epoch is never compared (not ranked); the followers decide",
    (order ep [cp "a" (some "1:old") (some 999), cp "b" ep (some 3)]) ==
      { ranked := ["b"], proof := .proven })]
  r := r ++ [("failover order: only other-history copies -> no follower, nothing ranked (existing tiers decide)",
    (order ep [cp "a" (some "1:old") (some 999)]).proof == .noFollower
      && (order ep [cp "a" (some "1:old") (some 999)]).ranked.isEmpty)]
  r := r ++ [("failover order: a follower with an unreadable position makes the order NOT proven",
    (order ep [cp "a" ep none, cp "b" ep (some 3)]) == { ranked := ["b"], proof := .unreadable })]
  r := r ++ [("failover order: the last master's epoch unknown -> nothing ranked",
    (order none [cp "a" ep (some 3)]) == {})]
  r := r ++ [("failover order: equal positions keep input order",
    (order ep [cp "a" ep (some 5), cp "b" ep (some 5)]).ranked == ["a", "b"])]
  r := r ++ [("refill: without a ranking the first slave in map order is seated (as before)",
    refill [] == some "a")]
  r := r ++ [("refill: two followers, the larger applied position (b) is promoted over map order",
    refill ["b", "a"] == some "b")]
  r := r ++ [("refill: a ranked key the gates block is skipped; the next ranked is seated",
    refill ["b", "c", "a"] ["b"] == some "c")]
  r := r ++ [("refill: ranking never admits a key the gates reject (all blocked -> none)",
    refill ["b"] ["a", "b", "c"] == none)]
  -- review of 7feb0e8: spec 4 promotes the largest applied position of the
  -- last master's epoch; a holder behind it would lose acknowledged writes
  r := r ++ [("refill: a PROVEN ranking wins over the recorded history holder (the holder c is behind b)",
    refill ["b", "a"] [] [] (some "c") == some "b")]
  r := r ++ [("refill: the holder is seated when no ranked key passes the gates",
    refill ["b"] ["b"] [] (some "c") == some "c")]
  r := r ++ [("refill: without a proven ranking the holder still wins over map order",
    refill [] [] [] (some "c") == some "c")]
  r := r ++ [("refill: the newest copy wins over the standby preference",
    refill ["b", "a"] [] ["b"] == some "b")]
  return r

end FlareOperator.UnitTestsFailover
