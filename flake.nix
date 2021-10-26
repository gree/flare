{
  description = "flare";

  nixConfig = {
    bash-prompt = "\[\\e[1m\\e[32mdev-flare\\e[0m:\\w\]$ ";
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self
            , nixpkgs
            , flake-utils
            , ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs {inherit system;};
          flare = import ./nix/default.nix {
            inherit pkgs;
          };
          shell = import ./nix/shell.nix {
            inherit pkgs;
          };
      in {
        # Exported packages.
        defaultPackage = flare;
        packages = {
          inherit flare;
        };
        devShell = shell;
      }
    );
}
