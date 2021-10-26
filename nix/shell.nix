{pkgs}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
in
mkShell {
  nativeBuildInputs = [ boost autoconf automake libtool zlib libmemcached tokyocabinet libuuid cutter ];
}
