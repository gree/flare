with import <nixpkgs> {};

stdenv.mkDerivation {
  name = "flare";
  src = ./.;
  doCheck = true;
  buildInputs = [ boost autoconf automake libtool zlib libmemcached tokyocabinet libuuid ];

  buildPhase = ''
    ./autogen.sh
    ./configure
    make
  '';

  installPhase = ''
    make install DESTDIR=$out
  '';
}
