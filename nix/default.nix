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
