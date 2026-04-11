/-
  E2E/Main.lean - Test executable entry point

  Registers all test suites and runs them via the E2E framework.
  Supports --filter <name> to run a single suite and --list to list suites.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Tests.Failover
import FlareOperator.E2E.Tests.ScaleOutMaster
import FlareOperator.E2E.Tests.ScaleOutSlave
import FlareOperator.E2E.Tests.ScaleInSlave
import FlareOperator.E2E.Tests.ScaleInMaster
import FlareOperator.E2E.Tests.ReplaceNodes
import FlareOperator.E2E.Tests.ClusterReplication
import FlareOperator.E2E.Tests.PartitionReduction
import FlareOperator.E2E.Tests.WalRetentionConfig

open FlareOperator.E2E

def main (args : List String) : IO UInt32 :=
  e2eMain [
    Tests.Failover.suite,
    Tests.ScaleOutMaster.suite,
    Tests.ScaleOutSlave.suite,
    Tests.ScaleInSlave.suite,
    Tests.ScaleInMaster.suite,
    Tests.ReplaceNodes.suite,
    Tests.ClusterReplication.suite,
    Tests.PartitionReduction.suite,
    Tests.WalRetentionConfig.suite
  ] args
