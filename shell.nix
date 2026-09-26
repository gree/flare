{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "dev-shell";

  # Packages to install in the environment
  buildInputs = with pkgs; [
    pkg-config
    cmake
    (python311.withPackages (ps: with ps; [numpy matplotlib pyyaml pandas pip]))
    nodejs
    boost
    autoconf
    automake
    libtool
    zlib
    libmemcached
    tokyocabinet
    (if stdenv.isDarwin then libossp_uuid else libuuid)
    (callPackage ./nix/cutter.nix {})
    elan
  ];

  # Environment variables
  shellHook = ''
  '';
}
