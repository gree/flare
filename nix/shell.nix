{pkgs
,flare-tests
,system}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
in
mkShell {
  buildInputs = [
    boost
    autoconf
    automake
    libtool
    zlib
    libmemcached
    tokyocabinet
    (if system == "x86_64-darwin" then libossp_uuid else libuuid)
    cutter
    pkgconfig
    flare-tests
  ];
}
