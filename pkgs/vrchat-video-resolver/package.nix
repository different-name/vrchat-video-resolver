{
  lib,
  stdenvNoCC,
  writeShellApplication,
  zig,
  yt-dlp,
  curl,
  coreutils,
  gnugrep,
  libnotify,

  cookiesFile ? null,
  cookiesFromBrowser ? null,

  port ? 9970,
}:
let
  resolver = writeShellApplication {
    # wine runs anything named .exe, but not an extensionless shebang script
    name = "vrchat-video-resolver.exe";
    runtimeInputs = [
      coreutils
      gnugrep
    ];
    text = ''
      YTDLP=${lib.getExe yt-dlp}
      CURL=${lib.getExe curl}
      NOTIFY_SEND=${lib.getExe' libnotify "notify-send"}
      COOKIES_BROWSER=${lib.optionalString (cookiesFromBrowser != null) cookiesFromBrowser}
      COOKIES_FILE=${lib.optionalString (cookiesFile != null) cookiesFile}
      PORT=${toString port}
      ${builtins.readFile ./resolve.sh}
    '';
  };

  toWin = path: "Z:" + lib.replaceStrings [ "/" ] [ "\\\\" ] path;
in
assert lib.assertMsg (
  cookiesFile == null || cookiesFromBrowser == null
) "vrchat-video-resolver: set at most one of cookiesFile and cookiesFromBrowser";
stdenvNoCC.mkDerivation {
  pname = "vrchat-video-resolver-stub";
  version = "0.1.0";

  src = builtins.path {
    path = ./shim.c;
    name = "vrchat-video-resolver.c";
  };

  dontUnpack = true;

  nativeBuildInputs = [
    zig
  ];

  buildPhase = ''
    export XDG_CACHE_HOME="$TMPDIR/zig-cache"
    zig build-exe $src \
      --name yt-dlp \
      -target x86_64-windows-gnu \
      -O ReleaseSmall \
      -lc \
      -lws2_32 \
      -DRESOLVER_WIN='"${toWin (lib.getExe resolver)}"' \
      -DLOGFILE_WIN='"C:\\users\\steamuser\\AppData\\LocalLow\\VRChat\\VRChat\\Tools\\vrchat-video-resolver-stub.log"'
  '';

  installPhase = ''
    install -Dm444 yt-dlp.exe $out/bin/yt-dlp.exe
  '';

  meta = {
    description = "Drop-in yt-dlp replacement that remuxes YouTube for VRChat's video players";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
