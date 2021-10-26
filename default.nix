{pkgs}:
with pkgs;
stdenv.mkDerivation {
  name = "flare";
  src = ./.;
  doCheck = true;
  buildInputs = [ boost autoconf automake libtool zlib libmemcached tokyocabinet libuuid ];

  buildPhase = ''
    ./autogen.sh
    ./configure
    make -j$NIX_BUILD_CORES
  '';

  installPhase = ''
    make install DESTDIR=$out
  '';
}
