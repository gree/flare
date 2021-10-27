{pkgs
,flare-tests}:
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
    libuuid
    cutter
    pkgconfig
    flare-tests
  ];
}
