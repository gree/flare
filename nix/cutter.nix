{pkgs}:
with pkgs;
stdenv.mkDerivation {
  name = "cutter";
  src = fetchFromGitHub {
    owner = "clear-code";
    repo = "cutter";
    rev = "01af87f69c2ae7c8123fb4964dfdb520589e60f2";
    hash = "sha256-tyE7jNfXZ4P7zU8m1A8jDkwqtQNNjfTQUx/Rov18rXo=";
  };
  buildInputs = [ autoconf automake libtool intltool glib m4 pkg-config ];
  patches = [../cutter.patch];

  buildPhase = ''
    ./autogen.sh
    ./configure --prefix=$out
    make -j$NIX_BUILD_CORES
  '';

  installPhase = ''
    make install
  '';
}
