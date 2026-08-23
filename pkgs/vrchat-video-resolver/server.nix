{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  yt-dlp,
  ffmpeg,

  port ? 9970,
  maxHeight ? 1080,
  cacheMb ? 512,
  cookiesFile ? null,
  cookiesFromBrowser ? null,
}:
let
  cookies =
    if cookiesFromBrowser != null then
      [
        "--cookies-from-browser"
        cookiesFromBrowser
      ]
    else if cookiesFile != null then
      [
        "--cookies"
        cookiesFile
      ]
    else
      [ ];
in
assert lib.assertMsg (
  cookiesFile == null || cookiesFromBrowser == null
) "vrchat-video-resolver: set at most one of cookiesFile and cookiesFromBrowser";
stdenvNoCC.mkDerivation {
  pname = "vrchat-video-resolver-server";
  version = "0.1.0";

  src = ./server.py;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm444 $src $out/share/vrchat-video-resolver/server.py
    makeWrapper ${lib.getExe python3} $out/bin/vrchat-video-resolver-server \
      --add-flags $out/share/vrchat-video-resolver/server.py \
      --set VVR_YTDLP ${lib.getExe yt-dlp} \
      --set VVR_FFMPEG ${lib.getExe ffmpeg} \
      --set VVR_PORT ${toString port} \
      --set VVR_MAX_HEIGHT ${toString maxHeight} \
      --set VVR_CACHE_MB ${toString cacheMb} \
      --set VVR_COOKIES ${lib.escapeShellArg (builtins.toJSON cookies)}
  '';

  meta = {
    description = "Serves VRChat's YouTube videos as HLS, remuxed on demand";
    mainProgram = "vrchat-video-resolver-server";
    platforms = [ "x86_64-linux" ];
  };
}
