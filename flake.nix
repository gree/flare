{
  description = "flare";

  nixConfig = {
    bash-prompt = "\[\\e[1m\\e[32mdev-flare\\e[0m:\\w\]$ ";
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?rev=2558d8e64f3816ec4291555fc8dc2212bd21f0a8";
    flake-utils.url = "github:numtide/flake-utils";
    flare-tests.url = "github:gree/flare-tests";
    flare-tests.inputs.nixpkgs.follows = "nixpkgs";
    flare-tests.inputs.flake-utils.follows = "flake-utils";
    flare-tools.url = "github:gree/flare-tools";
    flare-tools.inputs.nixpkgs.follows = "nixpkgs";
    flare-tools.inputs.flake-utils.follows = "flake-utils";
  };

  outputs = { self
            , nixpkgs
            , flake-utils
            , flare-tests
            , flare-tools
            , ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs {inherit system;};
          flare-tests-exe = flare-tests.packages.${system}.flare-tests;
          flare-tools-exe = flare-tools.packages.${system}.flare-tools;
          flare = import ./nix/default.nix {
            inherit pkgs;
            inherit system;
            flare-tests = flare-tests-exe;
          };
          shell = import ./nix/shell.nix {
            inherit pkgs;
            inherit system;
            flare-tools = flare-tools-exe;
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
