inputs: format:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.services.vrchat-video-resolver;

  inherit (lib) mkIf mkOption types;

  args = {
    inherit (cfg) port;
    yt-dlp = cfg.yt-dlp;
    cookiesFile = cfg.cookies.file;
    cookiesFromBrowser = cfg.cookies.fromBrowser;
  };

  stub = pkgs.callPackage ../pkgs/vrchat-video-resolver/package.nix args;
  server = pkgs.callPackage ../pkgs/vrchat-video-resolver/server.nix (
    args
    // {
      inherit (cfg) maxHeight cacheMb;
    }
  );

  hasSteamConfig = lib.hasAttrByPath [ "programs" "steam" "config" "apps" ] options;
  toolsPath = "drive_c/users/steamuser/AppData/LocalLow/VRChat/VRChat/Tools/yt-dlp.exe";
  vrchatAppId = "438100";
in
{
  options.services.vrchat-video-resolver = {
    enable = lib.mkEnableOption "the VRChat video resolver";

    yt-dlp = mkOption {
      type = types.package;
      default = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.yt-dlp;
      defaultText = lib.literalMD "`yt-dlp` from this flake's nixpkgs";
      description = "The yt-dlp package to resolve with.";
    };

    port = mkOption {
      type = types.port;
      default = 9970;
      description = ''
        Loopback port the server listens on.

        The replacement `yt-dlp.exe` is built with this port baked in, so changing it rebuilds both halves.
      '';
    };

    maxHeight = mkOption {
      type = types.ints.positive;
      default = 1080;
      description = ''
        Tallest video stream to select.

        A world can request a lower cap, in which case the lower of the two applies.
      '';
    };

    cacheMb = mkOption {
      type = types.ints.positive;
      default = 512;
      description = ''
        Memory the server may use holding segments it has already built.

        The least recently used segment is dropped once the limit is reached.
      '';
    };

    cookies = {
      fromBrowser = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "firefox:$HOME/.config/mozilla/firefox/ytdlp";
        description = ''
          Browser profile to read YouTube cookies from, in yt-dlp's `--cookies-from-browser` syntax.

          `$HOME` is expanded when the server starts. Set at most one of this and `cookies.file`.
        '';
      };

      file = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "$HOME/cookies.txt";
        description = ''
          Cookies file in Netscape format, read instead of a browser profile.

          `$HOME` is expanded when the server starts. Set at most one of this and `cookies.fromBrowser`.
        '';
      };
    };

    boundTo = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "steam-app-vrchat.target";
      description = ''
        Unit the server's lifetime follows, started and stopped alongside it.

        `null` leaves the server running for the whole session.
      '';
    };

    steamConfig.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether to configure VRChat through steam-config-nix.

        Installs the replacement `yt-dlp.exe` into VRChat's prefix and ties the server to the app's systemd target, so it runs only while the game is running. Requires the steam-config-nix module.
      '';
    };

    stub = mkOption {
      type = types.package;
      readOnly = true;
      default = stub;
      defaultText = lib.literalMD "the built replacement `yt-dlp.exe`";
      description = ''
        Package containing the replacement `yt-dlp.exe` at `bin/yt-dlp.exe`.

        Install it into VRChat's prefix yourself when `steamConfig.enable` is not set.
      '';
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.cookies.file == null || cfg.cookies.fromBrowser == null;
            message = "services.vrchat-video-resolver: set at most one of cookies.file and cookies.fromBrowser";
          }
          {
            assertion = !cfg.steamConfig.enable || hasSteamConfig;
            message = "services.vrchat-video-resolver: steamConfig.enable is set but the steam-config-nix module is not imported";
          }
        ];

        systemd.user.services.vrchat-video-resolver =
          let
            unit = {
              Description = "Resolves VRChat's video urls, remuxing YouTube to something its players accept";
              PartOf = lib.optional (cfg.boundTo != null) cfg.boundTo;
            };
            service = {
              ExecStart = lib.getExe server;
              Restart = "on-failure";
            };
            wantedBy = if cfg.boundTo != null then [ cfg.boundTo ] else [ "default.target" ];
          in
          if format == "nixos" then
            {
              description = unit.Description;
              partOf = unit.PartOf;
              serviceConfig = service;
              inherit wantedBy;
            }
          else
            {
              Unit = unit;
              Service = service;
              Install.WantedBy = wantedBy;
            };
      }

      # only touch steam-config-nix's options when its module is actually imported
      (lib.optionalAttrs hasSteamConfig (
        lib.mkIf cfg.steamConfig.enable {
          services.vrchat-video-resolver.boundTo =
            lib.mkDefault
              config.programs.steam.config.apps.${vrchatAppId}.systemd.target.unitName;

          # keyed by id, so this works whatever the app is named
          programs.steam.config.apps.${vrchatAppId} = {
            name = lib.mkDefault "VRChat";
            systemd.enable = true;
            files.prefix.place.${toolsPath} = {
              source = "${stub}/bin/yt-dlp.exe";
              # vrchat replaces this at launch unless it is read-only
              mode = "lock";
            };
          };
        }
      ))
    ]
  );
}
