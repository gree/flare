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
  '';
  installPhase = ''
    make install
  '';
}
