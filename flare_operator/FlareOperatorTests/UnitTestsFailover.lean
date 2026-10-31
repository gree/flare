/-
  UnitTestsFailover.lean — checks of StateMachine/FailoverOrder.lean and its
  use by the masterless refill (K8sReconciler.promoteMasterlessPartition):
  among the followers of the last master the largest applied position is
  promoted. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.FailoverOrder
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.UnreachableNode
import FlareOperator.StateMachine.DuplicateMaster

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

  -- spec 12 (2026-10-31): operator-unreachable nodes -> down, with the guard
  let mkState : FlareClusterState :=
    ({ nodeMap := [("m", node "m" .Master .Active 0), ("s", node "s" .Slave .Active 0),
                   ("t", node "t" .Slave .Active 0), ("p", node "p" .Proxy .Active (-1))],
       nodeMapVersion := 7 } : FlareClusterState).rebuildPartitionMap
  let step := FlareOperator.UnreachableNode.step
  let v1 := step [] [("m", false), ("s", true), ("t", true)] mkState
  let v2 := step v1.streaks [("m", false), ("s", true), ("t", true)] mkState
  let v3 := step v2.streaks [("m", false), ("s", true), ("t", true)] mkState
  r := r ++ [("unreachable: flarei's defaults (3 probes, 5 s, 1000 ms) are the operator's",
    FlareOperator.UnreachableNode.monitorThreshold == 3 && FlareOperator.UnreachableNode.monitorIntervalSec == 5
      && FlareOperator.UnreachableNode.monitorReadTimeoutMs == 1000)]
  r := r ++ [("unreachable: one or two failed probes do not make a node down",
    v1.down.isEmpty && v2.down.isEmpty && v2.streaks == [("m", 2)])]
  r := r ++ [("unreachable: the third consecutive failed probe makes it down",
    v3.down == ["m"] && !v3.guardTripped)]
  r := r ++ [("unreachable: a successful probe in between restarts the count",
    (step v2.streaks [("m", true), ("s", true), ("t", true)] mkState).streaks.isEmpty)]
  r := r ++ [("unreachable: a Proxy (no role to fail over) never counts",
    (step [("p", 5)] [("p", false), ("s", true)] mkState).down.isEmpty)]
  let g := step [("m", 2)] [("m", false), ("s", false), ("t", false)] mkState
  r := r ++ [("unreachable GUARD: every probed node unreachable -> nothing down, streaks restart, guard tripped",
    g.down.isEmpty && g.streaks.isEmpty && g.guardTripped)]
  r := r ++ [("unreachable GUARD: a stale streak cannot fire the moment the guard releases",
    (step g.streaks [("m", false), ("s", true), ("t", true)] mkState).down.isEmpty)]
  r := r ++ [("unreachable GUARD: no probe at all (empty list) is not a tripped guard",
    !(step [] [] mkState).guardTripped)]
  r := r ++ [("unreachable GUARD: even when only the lone Active node is probed and unreachable",
    (step [("m", 9)] [("m", false)] mkState).guardTripped)]
  let kept := fun (unhealthy : List String) =>
    K8sReconciler.unhealthyMastersKept mkState unhealthy unhealthy ["m", "s", "t", "p"]
  r := r ++ [("unreachable master with a reachable slave: not kept -> failed over",
    (kept ["m"]).isEmpty)]
  r := r ++ [("unreachable master, every slave also unreachable: no successor -> kept as master",
    kept ["m", "s", "t"] == ["m"])]
  r := r ++ [("unreachable master, one slave unreachable and one reachable: failed over to the reachable",
    (kept ["m", "s"]).isEmpty)]
  r := r ++ [("unreachable slave: down (failed over to proxy), never kept",
    (kept ["s"]).isEmpty)]
  -- spec 13: a master claim the committed map gives to another node
  let dm : FlareClusterState :=
    ({ nodeMap := [("a", node "a" .Master .Active 0), ("b", node "b" .Slave .Active 0)],
       nodeMapVersion := 7 } : FlareClusterState).rebuildPartitionMap
  let reply := fun (role : String) (part : Int) => s!"STAT own_role {role}\r\nSTAT own_partition {part}\r\nSTAT node_map_version 6\r\nEND\r\n"
  r := r ++ [("duplicate master: a node claiming the master the map gives to ANOTHER node conflicts; the map's own master, a slave claim or no partition does not",
    (DuplicateMaster.ownClaim (reply "master" 0)).map (DuplicateMaster.conflicts dm "b") == some true
      && (DuplicateMaster.ownClaim (reply "master" 0)).map (DuplicateMaster.conflicts dm "a") == some false
      && (DuplicateMaster.ownClaim (reply "slave" 0)).map (DuplicateMaster.conflicts dm "b") == some false
      && (DuplicateMaster.ownClaim (reply "proxy" (-1))).map (DuplicateMaster.conflicts dm "b") == some false
      && DuplicateMaster.ownClaim "STAT own_role master\r\nEND\r\n" == none)]
  let h := DuplicateMaster.holdMs
  r := r ++ [("duplicate master: down only after the claim stood holdMs (15 s, flarei's 3 x 5 s); fast passes do not shorten it",
    h == 15000
      && (DuplicateMaster.step [] "b" (some true) 1000) == ([("b", 1000)], false)
      && (DuplicateMaster.step [("b", 1000)] "b" (some true) 1200).2 == false
      && (DuplicateMaster.step [("b", 1000)] "b" (some true) (1000 + h)).2 == true)]
  r := r ++ [("duplicate master: a claim that ends clears it; an unreadable sample keeps what was known and never starts a count",
    (DuplicateMaster.step [("b", 1000)] "b" (some false) 99000) == ([], false)
      && (DuplicateMaster.step [] "b" none 99000) == ([], false)
      && (DuplicateMaster.step [("b", 1000)] "b" none (1000 + h)).2 == true)]
  return r

end FlareOperator.UnitTestsFailover
