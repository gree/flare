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
import FlareOperator.E2E.Tests.StrictDurability
import FlareOperator.E2E.Tests.WalBandwidthThrottle
import FlareOperator.E2E.Tests.WalIncrementalSync
import FlareOperator.E2E.Tests.WalPurgedFallback
import FlareOperator.E2E.Tests.ResyncFailureSelfDemote
import FlareOperator.E2E.Tests.OrphanScanPurge
import FlareOperator.E2E.Tests.TerminatingPodHandling
import FlareOperator.E2E.Tests.FailoverDuringReplication
import FlareOperator.E2E.Tests.DataSurvivalFailover
import FlareOperator.E2E.Tests.PvcDataSurvival
import FlareOperator.E2E.Tests.BackupRestore
import FlareOperator.E2E.Tests.CircuitBreaker
import FlareOperator.E2E.Tests.OperatorRestart
import FlareOperator.E2E.Tests.NativeMetrics
import FlareOperator.E2E.Tests.BlueGreenMigration
import FlareOperator.E2E.Tests.SnapshotPushSeed

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
    Tests.WalRetentionConfig.suite,
    Tests.StrictDurability.suite,
    Tests.WalBandwidthThrottle.suite,
    Tests.WalIncrementalSync.suite,
    Tests.WalPurgedFallback.suite,
    Tests.ResyncFailureSelfDemote.suite,
    Tests.OrphanScanPurge.suite,
    Tests.TerminatingPodHandling.suite,
    Tests.FailoverDuringReplication.suite,
    Tests.DataSurvivalFailover.suite,
    Tests.PvcDataSurvival.suite,
    Tests.BackupRestore.suite,
    Tests.CircuitBreaker.suite,
    Tests.OperatorRestart.suite,
    Tests.NativeMetrics.suite,
    Tests.BlueGreenMigration.suite,
    Tests.SnapshotPushSeed.suite
  ] args
