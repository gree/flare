{pkgs
,flare-tests
,system}:
with pkgs;
let cutter = callPackage ./cutter.nix {};
in
stdenv.mkDerivation {
  name = "flare";
  src = pkgs.lib.cleanSourceWith {
    filter = (path: type: 
      if (type == "directory" && baseNameOf path == "nix") ||
         (type == "regular" && builtins.match "(.*\.nix)|(flake.lock)" (baseNameOf path) != null)
      then false
      else true # builtins.trace (type + ":" + baseNameOf path) true
    );
    src = ./..;
  };
  doCheck = true;
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
  ];

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
