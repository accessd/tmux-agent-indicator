{
  description = "tmux plugin showing AI agent state in pane borders, window titles and the status bar";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      version = "unstable-${self.shortRev or self.dirtyShortRev or "dirty"}";
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      packages = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix { inherit version; };
      });

      homeModules.default = import ./nix/hm-module.nix { inherit version; };

      checks = forAllSystems (system: {
        package = self.packages.${system}.default;
        hm-module = import ./nix/checks.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          hmModule = self.homeModules.default;
        };
      });
    };
}
