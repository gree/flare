{pkgs
,flare-tests
,system
,enableRocksdb ? false}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
in
stdenv.mkDerivation {
  name = if enableRocksdb then "flare-rocksdb" else "flare";
  src = pkgs.lib.cleanSourceWith {
    filter = (path: type:
      if (type == "directory" && baseNameOf path == "nix") ||
         (type == "regular" && builtins.match "(.*\.nix)|(flake.lock)" (baseNameOf path) != null)
      then false
      else true # builtins.trace (type + ":" + baseNameOf path) true
    );
    src = ./..;
  };
  doCheck = true;
  buildInputs = [
    boost
    autoconf
    automake
    libtool
    zlib
    libmemcached
    tokyocabinet
    (if stdenv.isDarwin then libossp_uuid else libuuid)
    cutter
    pkg-config
  ] ++ pkgs.lib.optionals enableRocksdb [
    rocksdb
  ];

  buildPhase = ''
    ./autogen.sh
    ${if enableRocksdb then ''
      ./configure --prefix=$out --with-rocksdb=${rocksdb}
    '' else ''
      ./configure --prefix=$out
    ''}

    make -j$NIX_BUILD_CORES
  '';
  checkPhase = ''
    make check || {
      echo "=== Test failed, showing test-suite.log ==="
      cat test/test-suite.log || echo "test-suite.log not found"
      exit 1
    }
    # Evidence in the CI log: the cutter totals, and the tests named by the
    # release checklist (R3 source eligibility, R10 boot id), by name.
    echo "=== cutter summary (test/run-tests.sh.log) ==="
    grep -E 'test\(s\),' test/run-tests.sh.log || echo "no cutter summary line found"
    grep -E 'test_source_eligibility::|test_boot_ids_differ' test/run-tests.sh.log || echo "named checklist tests not found in the cutter log"
    # the history change's C++ test (bulk receipt / pending marker), by name:
    # the totals alone did not show whether it ran (CI 37834294235)
    grep -E 'test_bulk_receipt_normal_failed_write_and_crash_before_epoch' test/run-tests.sh.log || echo "bulk receipt test NOT found in the cutter log"
    # verification V capture decoder (flared --dump-checkpoint), by name
    grep -E 'test_dump_checkpoint_point_in_time_and_side_effect_free' test/run-tests.sh.log || echo "dump_checkpoint test NOT found in the cutter log"
    # capture guards: write bounds for a connected peer that stops reading,
    # worst-case-pin capacity rule
    # switch gate: in-flight forwards as a value, one outcome per forward on shutdown
    grep -E 'test_in_flight_counts_a_forward_until_it_is_released|test_repl_in_flight_counts_per_destination_until_released|test_repl_in_flight_released_per_destination_before_the_item_goes|test_proxy_write_outcomes_are_counted_per_destination|test_in_flight_and_outcomes_on_shutdown|test_foreign_outcome_counters_are_the_gate_set|test_enqueue_after_the_handler_returned_is_refused|test_post_proxy_forward_is_not_handed_to_a_reused_thread' test/run-tests.sh.log || echo "in-flight tests NOT found in the cutter log"
    grep -E 'test_map_swap_waits_for_a_write_in_its_section|test_map_swap_is_not_starved_by_a_steady_write_load|test_a_waiting_map_swap_is_preferred_over_a_new_write|test_write_section_depth_is_per_cluster_instance' test/run-tests.sh.log || echo "write section test NOT found in the cutter log"
    # L12: an in-cluster forward to a replica that does not answer is held and resent, not dropped
    grep -E 'test_in_cluster_forward_without_hold_is_dropped|test_in_cluster_forward_is_held_until_the_replica_answers|test_in_cluster_hold_gives_up_then_tries_once_each|test_in_cluster_server_error_is_retried_within_the_hold|test_in_cluster_hold_is_bounded_by_a_silent_replica|test_in_cluster_hold_is_bounded_by_a_blackholed_connect|test_in_cluster_given_up_is_shared_by_every_forwarding_thread|test_in_cluster_concurrent_holds_overlap|test_in_cluster_refusal_through_the_hold_gives_the_replica_up|test_proxy_write_held_counters|test_a_write_waits_for_a_master_while_the_partition_has_none|test_a_write_waiting_for_a_master_fails_at_the_bound|test_a_replica_applies_only_changes_from_a_master_of_the_partition' test/run-tests.sh.log || echo "held forward tests NOT found in the cutter log"
    # reseed / dump serve: progress bound, no total deadline (round 8)
    grep -E 'test_reseed_serve_ends_when_the_receiver_stops_reading|test_reseed_serve_to_a_slow_reader_completes_past_several_windows|test_run_server_ends_when_the_receiver_stops_reading|test_final_frame_is_bounded_when_only_it_is_stuck|test_bound_is_off_after_a_complete_dump' test/run-tests.sh.log || echo "serve bound tests NOT found in the cutter log"
    # per-key-only migration: the destination refuses a snapshot push with the switch off
    grep -E 'test_switch_off_refuses_an_incoming_push_before_anything_else|test_switch_on_does_not_refuse_by_the_switch' test/run-tests.sh.log || echo "snapshot push switch tests NOT found in the cutter log"
    grep -E 'test_proxy_enqueue_is_not_handed_to_a_reused_thread|test_noreply_client_write_skipped_to_a_proxy_goes_to_the_master_in_force|test_typed_enqueue_is_not_handed_to_a_reused_thread|test_broadcast_is_not_handed_to_a_reused_thread|test_broadcast_to_a_prior_node_is_not_handed_to_a_reused_thread' test/run-tests.sh.log || echo "in-cluster reuse tests NOT found in the cutter log"
    # T24: the identity/size probe retries with a fresh lookup (round 8)
    grep -E 'test_probe_reaches_a_source_that_answers_only_on_a_later_attempt|test_probe_of_an_unreachable_source_is_unanswered_and_bounded' test/run-tests.sh.log || echo "probe retry tests NOT found in the cutter log"
    grep -E 'test_write_progress_timeout_ends_a_write_to_a_peer_that_stopped_reading|test_write_deadline_ends_a_write_even_with_a_longer_progress_timeout|test_write_bounds_do_not_end_a_write_the_peer_reads|test_capture_capacity_refuses_unknowns_and_short_space' test/run-tests.sh.log || echo "capture guard tests NOT found in the cutter log"
    # CI 37852139711: the RocksDB and the legacy builds reported the SAME
    # totals, so the RocksDB storage module was built but not run. Show what
    # cutter loaded and why a module was not, and FAIL a RocksDB build whose
    # storage tests did not run (a skipped module is never a pass).
    echo "=== test modules built ==="
    ls test/lib/.libs/*.so 2>/dev/null || echo "no test modules in test/lib/.libs"
    echo "=== cutter warnings / load errors ==="
    grep -iE 'warn|error|cannot|undefined|failed to|load' test/run-tests.sh.log | grep -vE '^ *test_' | head -40 || true
    echo "=== modules that ran ==="
    grep -oE '^ *test_[a-z0-9_]+::' test/run-tests.sh.log | sort | uniq -c || true
    ${if enableRocksdb then ''
      if ! grep -qE 'test_storage_rocksdb::' test/run-tests.sh.log; then
        echo "RocksDB storage tests (test_storage_rocksdb) did NOT run: failing the build"
        ldd test/lib/.libs/test_storage_rocksdb.so 2>&1 | grep -i 'not found' || true
        exit 1
      fi
    '' else ""}
  '';
  installPhase = ''
    make install
  '';
}
