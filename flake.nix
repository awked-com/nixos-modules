{
  description = "Reusable NixOS service modules maintained by awked-com";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      evaluate =
        system:
        import ./tests/eval.nix {
          inherit nixpkgs system;
          modules = self.nixosModules;
          moduleLib = self.lib;
        };
    in
    {
      nixosModules = {
        cast = ./modules/cast;
        amneziawg-go = ./modules/networking/amneziawg-go.nix;
        sops-credential-restarts = ./modules/base/sops-restarts.nix;
        nix-ci-cache = ./modules/nix-ci-cache.nix;
      };

      lib = {
        networkingValidation = import ./modules/networking/validation.nix;
        qemuVM = import ./modules/qemu-vm;
        pinnedBindSources = import ./modules/containers/pinned-bind-sources.nix;
        evaluationTests = forAllSystems evaluate;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          results = evaluate system;
        in
        {
          module-evaluation =
            pkgs.runCommand "nixos-modules-evaluation"
              {
                result = builtins.toJSON results;
              }
              ''
                printf '%s\n' "$result" > "$out"
              '';
        }
      );

      formatter = nixpkgs.lib.genAttrs (systems ++ [ "aarch64-darwin" ]) (
        system: nixpkgs.legacyPackages.${system}.nixfmt-tree
      );
    };
}
