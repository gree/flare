{
  description = "flare";

  nixConfig = {
    bash-prompt = "\[\\e[1m\\e[32mdev-flare\\e[0m:\\w\]$ ";
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    flare-tests.url = "github:gree/flare-tests";
  };

  outputs = { self
            , nixpkgs
            , flake-utils
            , flare-tests
            , ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs {inherit system;};
          flare-tests-exe = flare-tests.packages.${system}.flare-tests;
          flare = import ./nix/default.nix {
            inherit pkgs;
            flare-tests = flare-tests-exe;
          };
          shell = import ./nix/shell.nix {
            inherit pkgs;
            flare-tests = flare-tests-exe;
          };
          test-flare = with pkgs; runCommand "test-flare" {
            buildInputs = [
              flare
              flare-tests-exe
            ];
          } ''
              mkdir -p $out/
              export NIX_REDIRECTS=/etc/protocols=${iana-etc}/etc/protocols
              export LD_PRELOAD=${libredirect}/lib/libredirect.so
              flare-tests
              unset NIX_REDIRECTS LD_PRELOAD
              touch $out/done
          '';
      in {
        # Exported packages.
        defaultPackage = flare;
        packages = {
          inherit flare;
          inherit test-flare;
        };
        devShell = shell;
      }
    );
}
