port=$1
blob=$2

LOGFILE=${XDG_CACHE_HOME:-$HOME/.cache}/vrchat-video-resolver/shim.log
mkdir -p "$(dirname "$LOGFILE")"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOGFILE"; }

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

notify() { "$NOTIFY_SEND" -u critical "VRChat video" "$1" >/dev/null 2>&1 || true; }

# connect before doing any work, so the stub can tell a failed launch from a slow resolve
if ! exec 3<>/dev/tcp/127.0.0.1/"$port"; then
  log "could not reach the stub on port $port"
  exit 1
fi

mapfile -t args < <(printf '%s' "$blob" | base64 -d)

format=""
url=""
for i in "${!args[@]}"; do
  case ${args[i]} in
    -f) format=${args[i + 1]-} ;;
    http*) url=${args[i]} ;;
  esac
done

if [ -z "$url" ]; then
  log "no url in arguments"
  notify "No URL in arguments."
  exit 1
fi

case $url in
  *youtube.com* | *youtu.be*) youtube=1 ;;
  *) youtube=0 ;;
esac

log "url=$url"
log "  requested=${format:-none} youtube=$youtube"

cookies=()
if [ -n "${COOKIES_BROWSER:-}" ]; then
  cookies=(--cookies-from-browser "$COOKIES_BROWSER")
  log "  cookies: browser $COOKIES_BROWSER"
elif [ -n "${COOKIES_FILE:-}" ]; then
  if [ -r "$COOKIES_FILE" ]; then
    # --cookies writes the jar back, which rotates the session away over time
    copy=$scratch/cookies.txt
    cp "$COOKIES_FILE" "$copy"
    cookies=(--cookies "$copy")
    log "  cookies: copy of $COOKIES_FILE"
  else
    log "  cookies file missing: $COOKIES_FILE"
    notify "Cookies file is missing. YouTube quality will be degraded or fail."
  fi
fi

# without the server youtube caps at 360p
if [ "$youtube" = 1 ]; then
  # the world picks the height cap, so honour it rather than overriding it the way vvc does
  cap=$(printf '%s' "$format" | grep -o 'height<=?[0-9]*' | head -1 | grep -o '[0-9]*' || true)
  answer=$("$CURL" -sS --max-time 90 --write-out '\n%{http_code}' --get \
    --data-urlencode "url=$url" --data-urlencode "maxheight=${cap:-}" \
    "http://127.0.0.1:$PORT/prepare" 2>/dev/null) || true
  code=$(printf '%s' "$answer" | tail -n1)
  playlist=$(printf '%s' "$answer" | head -n1)

  case $code in
    200)
      log "  remuxed: $playlist"
      printf '%s\n' "$playlist" >&3
      exec 3>&-
      exit 0
      ;;
    204)
      # a livestream, nothing we could have improved on
      log "  not remuxable, resolving it plainly"
      ;;
    409)
      # youtube served no separate streams, which usually means yt-dlp is out of date
      log "  server could not remux this, resolving it plainly"
      notify "Could not remux this video, so quality is reduced. yt-dlp may be out of date."
      ;;
    *)
      log "  server on port $PORT answered $code, falling back to plain resolution"
      notify "Video resolver service is not answering. YouTube quality will be degraded."
      ;;
  esac
fi

selector=()
if [ -n "$format" ]; then selector=(-f "$format"); fi

# urls get their own --print because a merged format emits one per line
out=$("$YTDLP" --ignore-config --no-playlist --no-warnings --simulate --no-check-formats \
  "${cookies[@]}" "${selector[@]}" \
  --print '%(available_at)s|%(format_id)s|%(protocol)s|%(height)s' \
  --print urls \
  -- "$url" 2>"$scratch/err") || true

IFS='|' read -r available_at fmt_id protocol height <<<"$(printf '%s' "$out" | head -1)"
resolved=$(printf '%s' "$out" | tail -n +2)
first=$(printf '%s' "$resolved" | head -1)

if [ -z "$first" ]; then
  # vrchat plays the original url when nothing comes back, fine for a direct link
  if [ "$youtube" = 1 ]; then
    log "  resolve failed: $(tail -1 "$scratch/err")"
    notify "Could not resolve video."
  else
    log "  no format matched, leaving the url to vrchat"
  fi
  exit 1
fi

log "  selected=$fmt_id protocol=$protocol height=$height"
if [ "$(printf '%s\n' "$resolved" | wc -l)" -gt 1 ]; then
  # yt-dlp's own --get-url prints one url per line here, so pass them all on unchanged
  log "  merged format, emitting $(printf '%s\n' "$resolved" | wc -l) urls"
fi

# the manifest answers immediately but its segments do not, so poll a segment
if [ "${available_at:-0}" -gt "$(date +%s)" ] 2>/dev/null; then
  target=$first
  case $protocol in
    *m3u8*)
      segment=$("$CURL" -fsS --max-time 10 "$first" 2>/dev/null | grep -m1 '^https' || true)
      if [ -n "$segment" ]; then target=$segment; fi
      ;;
  esac
  began=$(date +%s)
  while :; do
    if "$CURL" -fsS -o /dev/null --max-time 5 -r 0-1 "$target" 2>/dev/null; then
      log "  servable after $(($(date +%s) - began))s (stated $((available_at - began))s)"
      break
    fi
    if [ "$(date +%s)" -ge "$available_at" ]; then
      log "  poll gave up after $(($(date +%s) - began))s"
      break
    fi
    sleep 0.5
  done
fi

printf '%s\n' "$resolved" >&3
exec 3>&-
log "  emitted ${#resolved} bytes"
