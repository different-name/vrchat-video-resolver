{
  description = "Drop-in yt-dlp replacement that remuxes YouTube for VRChat's video players";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      flake =
        let
          mkModule = import ./modules inputs;
        in
        {
          nixosModules = {
            default = inputs.self.nixosModules.vrchat-video-resolver;
            vrchat-video-resolver = mkModule "nixos";
          };

          homeModules = {
            default = inputs.self.homeModules.vrchat-video-resolver;
            vrchat-video-resolver = mkModule "home-manager";
          };
        };

      systems = import inputs.systems;

      perSystem =
        { self', pkgs, ... }:
        {
          packages = {
            default = self'.packages.vrchat-video-resolver-stub;
            vrchat-video-resolver-stub = pkgs.callPackage ./pkgs/vrchat-video-resolver/package.nix { };
            vrchat-video-resolver-server = pkgs.callPackage ./pkgs/vrchat-video-resolver/server.nix { };
          };

          formatter = pkgs.nixfmt-tree;
        };
    };
}
