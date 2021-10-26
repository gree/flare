{pkgs}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
in
stdenv.mkDerivation {
  name = "flare";
  src = ./..;
  doCheck = true;
  buildInputs = [ boost autoconf automake libtool zlib libmemcached tokyocabinet libuuid cutter pkgconfig ];

  buildPhase = ''
    ./autogen.sh
    ./configure --prefix=$out

    make -j$NIX_BUILD_CORES
  '';
  checkPhase = ''
    make check
  '';
  installPhase = ''
    make install
  '';
}
