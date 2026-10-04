{
  description = "Drop-in yt-dlp replacement that remuxes YouTube for VRChat's video players";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    # only used by the module eval checks
    steam-config-nix = {
      url = "github:different-name/steam-config-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        flake-parts.follows = "flake-parts";
      };
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
        {
          self',
          pkgs,
          lib,
          system,
          ...
        }:
        {
          packages = {
            default = self'.packages.vrchat-video-resolver-stub;
            vrchat-video-resolver-stub = pkgs.callPackage ./pkgs/vrchat-video-resolver/package.nix { };
            vrchat-video-resolver-server = pkgs.callPackage ./pkgs/vrchat-video-resolver/server.nix { };
          };

          checks =
            let
              enabled = {
                services.vrchat-video-resolver = {
                  enable = true;
                  steamConfig.enable = true;
                };
              };

              # naming the options the module writes, so a rename upstream fails the check
              # rather than evaluating to nothing
              wiring = config: [
                config.programs.steam.config.apps."438100".name
                (toString (builtins.attrNames config.programs.steam.config.apps."438100".files.prefix.place))
              ];
            in
            {
              # covers the shellcheck over the resolver and the cross compile of the stub
              inherit (self'.packages) vrchat-video-resolver-stub vrchat-video-resolver-server;

              formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
                nixfmt --check $(find ${inputs.self} -name '*.nix')
                touch $out
              '';

              server-compiles =
                pkgs.runCommand "check-server-compiles" { nativeBuildInputs = [ pkgs.python3 ]; }
                  ''
                    python3 -m py_compile ${./pkgs/vrchat-video-resolver/server.py}
                    touch $out
                  '';

              modules-nixos =
                let
                  eval = inputs.nixpkgs.lib.nixosSystem {
                    inherit system;
                    modules = [
                      inputs.self.nixosModules.default
                      inputs.steam-config-nix.nixosModules.default
                      enabled
                      { system.stateVersion = "25.05"; }
                    ];
                  };
                in
                pkgs.runCommand "check-modules-nixos" { } ''
                  echo ${toString eval.config.systemd.user.services.vrchat-video-resolver.serviceConfig.ExecStart} > $out
                  echo ${lib.escapeShellArgs (wiring eval.config)} >> $out
                '';

              modules-home-manager =
                let
                  eval = inputs.home-manager.lib.homeManagerConfiguration {
                    inherit pkgs;
                    modules = [
                      inputs.self.homeModules.default
                      inputs.steam-config-nix.homeModules.default
                      enabled
                      {
                        home = {
                          username = "check";
                          homeDirectory = "/home/check";
                          stateVersion = "25.05";
                        };
                      }
                    ];
                  };
                in
                pkgs.runCommand "check-modules-home-manager" { } ''
                  echo ${toString eval.config.systemd.user.services.vrchat-video-resolver.Service.ExecStart} > $out
                  echo ${lib.escapeShellArgs (wiring eval.config)} >> $out
                '';
            };

          formatter = pkgs.nixfmt-tree;
        };
    };
}
