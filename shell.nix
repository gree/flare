{pkgs}:
with pkgs;
mkShell {
  nativeBuildInputs = [ boost autoconf automake libtool zlib libmemcached tokyocabinet libuuid ];
}
