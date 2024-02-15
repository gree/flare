{pkgs
,flare-tests
,flare-tools
,system}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
    emacs-for-flare = callPackage ./emacs.nix {};
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
    (if stdenv.isDarwin then libossp_uuid else libuuid)
    cutter
    pkg-config
    flare-tests
    emacs-for-flare
    flare-tools
  ];
}
