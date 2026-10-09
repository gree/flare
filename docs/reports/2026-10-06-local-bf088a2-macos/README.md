# Local C++ test run on macOS (NOT equivalent to the Linux CI)

- Source: a scratch copy of the tracked files whose **source SHA/tree equal
  `bf088a22b70452d14c0177c63e5979a05a6789e2` / `a656e7860781e248809daaebbdb84248fbdeed01`**
  (`provenance.txt`; no uncommitted changes under `src`/`test`), **with the
  macOS compatibility patches below applied on top**. The tested build is
  therefore NOT identical to that commit's Linux build.
- Environment: macOS aarch64 (Darwin 25.6), `nix develop .#flare-rocksdb`
  (the package's build environment: RocksDB 8.3.2 from nixpkgs, clang),
  `./configure` (no extra flags), `make -j8`, `make check -j4`.
- macOS compatibility patches (scratch only, not in the repository):
  1. `CXXFLAGS=-std=c++17` — RocksDB 8.3 headers need C++17
     (`std::make_from_tuple`);
  2. `-D_LIBCPP_ENABLE_CXX17_REMOVED_RANDOM_SHUFFLE` — `cluster.cc` uses
     `std::random_shuffle`, removed from libc++ in C++17;
  3. `-I shim`: `shim/malloc.h` (glibc `mallinfo2` absent on macOS; the
     memory stats read 0 locally) and `shim/sys/vfs.h` (maps to
     `sys/mount.h`).
- Result: `5268 test(s), 4149731 assertion(s), 0 failure(s), 0 error(s),
  0 pending(s), 0 omission(s), 3 notification(s)` (the notifications are
  the pre-existing Tokyo Cabinet iterator tests). Every test added in this
  work is listed by name in `run-tests.log` and passed, including the three
  deadline tests (the connect test ended by ETIMEDOUT here, not omitted).
- Earlier local runs on older trees were superseded (one hung on a test bug
  since fixed) and are not counted.
