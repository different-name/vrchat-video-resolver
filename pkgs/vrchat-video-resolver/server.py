import hashlib
import json
import os
import re
import struct
import tempfile
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

YTDLP = os.environ["VVR_YTDLP"]
FFMPEG = os.environ["VVR_FFMPEG"]
PORT = int(os.environ.get("VVR_PORT", "9970"))
MAX_HEIGHT = int(os.environ.get("VVR_MAX_HEIGHT", "1080"))
CACHE_BYTES = int(os.environ.get("VVR_CACHE_MB", "512")) * 1024 * 1024
# expanded here so a configured path may use $HOME, which nix cannot know
COOKIES = [os.path.expandvars(c) for c in json.loads(os.environ.get("VVR_COOKIES", "[]"))]

# cuts land on fragment boundaries, the only points that start on a keyframe
TARGET_SEGMENT = 6.0

# youtube 403s a fresh stream until it is servable, so a 403 means not yet
AVAILABILITY_TRIES = 40


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


class Unsupported(Exception):
    # expected means plain resolution hits the same wall, so nobody needs telling
    def __init__(self, reason, expected):
        super().__init__(reason)
        self.expected = expected


def resolve(page, height):
    # one call for both streams, the trailing /b keeps it succeeding when nothing matches
    selector = (f"bv*[vcodec^=avc1][height<=?{height}]"
                "+ba[acodec^=mp4a][audio_channels<=2]/"
                f"bv*[vcodec^=avc1][height<=?{height}]+ba[acodec^=mp4a]/b")
    proc = subprocess.run(
        [YTDLP, "--ignore-config", "--no-playlist", "--no-warnings", "--simulate",
         "--no-check-formats", *COOKIES, "-f", selector,
         "--print",
         "%(requested_formats.0.format_id)s|%(requested_formats.0.height)s|%(is_live)s",
         "--print", "%(requested_formats.1.format_id)s",
         "--print", "%(requested_formats.0.url)s",
         "--print", "%(requested_formats.1.url)s", "--", page],
        capture_output=True, text=True)
    if proc.returncode != 0:
        # the selector ends in /b, so a failure here means nothing extracted at all
        raise Unsupported(proc.stderr.strip().split("\n")[-1][:160], expected=True)

    out = proc.stdout.strip().split("\n")
    meta = out[0].split("|")
    if len(out) != 4 or meta[0] == "NA":
        live = len(meta) > 2 and meta[2] == "True"
        raise Unsupported(
            "livestream" if live else "youtube offered no separate video and audio streams",
            expected=live,
        )
    return ({"id": meta[0], "h": meta[1], "url": out[2]},
            {"id": out[1], "url": out[3]})


def fetch(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    for attempt in range(AVAILABILITY_TRIES):
        try:
            data = urllib.request.urlopen(req, timeout=30).read()
            if attempt:
                log(f"  fetch succeeded on attempt {attempt + 1}")
            return data
        except urllib.error.HTTPError as e:
            if e.code != 403 or attempt == AVAILABILITY_TRIES - 1:
                raise
            time.sleep(1)
        except Exception:
            # googlevideo drops transfers mid-write as a matter of course
            if attempt == AVAILABILITY_TRIES - 1:
                raise
            time.sleep(0.5)


def read_layout(url):
    head = fetch(url, 0, 65535)
    init_end = sidx_at = sidx_len = None
    off = 0
    while off + 8 <= len(head):
        size = struct.unpack(">I", head[off:off + 4])[0]
        kind = head[off + 4:off + 8]
        if kind in (b"ftyp", b"moov"):
            init_end = off + size
        elif kind == b"sidx":
            sidx_at, sidx_len = off, size
            break
        if size < 8:
            break
        off += size
    if sidx_at is None:
        raise RuntimeError("stream has no sidx, cannot describe it as HLS")

    box = head[sidx_at + 8:sidx_at + sidx_len]
    timescale = struct.unpack(">I", box[8:12])[0]
    if box[0] == 0:
        first_offset = struct.unpack(">I", box[16:20])[0]
        pos_in_box = 20
    else:
        first_offset = struct.unpack(">Q", box[20:28])[0]
        pos_in_box = 28
    count = struct.unpack(">H", box[pos_in_box + 2:pos_in_box + 4])[0]
    pos_in_box += 4

    at, start, frags = sidx_at + sidx_len + first_offset, 0.0, []
    for _ in range(count):
        size = struct.unpack(">I", box[pos_in_box:pos_in_box + 4])[0] & 0x7FFFFFFF
        dur = struct.unpack(">I", box[pos_in_box + 4:pos_in_box + 8])[0] / timescale
        frags.append({"at": at, "size": size, "start": start, "dur": dur})
        at += size
        start += dur
        pos_in_box += 12
    return head[:init_end], frags


class Video:
    def __init__(self, page, height):
        self.page = page
        self.height = height
        self.lock = threading.Lock()
        self.load()

    def load(self):
        self.video, self.audio = resolve(self.page, self.height)
        self.vinit, self.vfrags = read_layout(self.video["url"])
        self.ainit, self.afrags = read_layout(self.audio["url"])
        self.segments, group = [], []
        for frag in self.vfrags:
            group.append(frag)
            if sum(f["dur"] for f in group) >= TARGET_SEGMENT:
                self.segments.append(group)
                group = []
        if group:
            self.segments.append(group)

    def playlist(self, base, key):
        durs = [sum(f["dur"] for f in g) for g in self.segments]
        lines = ["#EXTM3U", "#EXT-X-VERSION:3",
                 f"#EXT-X-TARGETDURATION:{max(1, round(max(durs)))}",
                 "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for i, dur in enumerate(durs):
            lines += [f"#EXTINF:{dur:.6f},", f"{base}/v/{key}/seg{i}.ts"]
        lines.append("#EXT-X-ENDLIST")
        return ("\n".join(lines) + "\n").encode()

    def segment(self, index):
        group = self.segments[index]
        start = group[0]["start"]
        end = start + sum(f["dur"] for f in group)
        try:
            return self.mux(group, start, end)
        except urllib.error.HTTPError as e:
            if e.code != 403:
                raise
            log("  re-resolving, a signed url expired")
            with self.lock:
                self.load()
            return self.mux(group, start, end)

    def mux(self, group, start, end):
        video = self.vinit + b"".join(
            fetch(self.video["url"], f["at"], f["at"] + f["size"] - 1) for f in group)
        overlap = [f for f in self.afrags
                   if f["start"] < end and f["start"] + f["dur"] > start]
        audio = self.ainit + b"".join(
            fetch(self.audio["url"], f["at"], f["at"] + f["size"] - 1) for f in overlap)
        # audio fragments do not share video boundaries, trim the front to line up
        skew = start - overlap[0]["start"] if overlap else 0.0

        with tempfile.TemporaryDirectory() as tmp:
            vpath = os.path.join(tmp, "v.mp4")
            apath = os.path.join(tmp, "a.mp4")
            with open(vpath, "wb") as f:
                f.write(video)
            with open(apath, "wb") as f:
                f.write(audio)
            proc = subprocess.run(
                [FFMPEG, "-v", "error", "-i", vpath, "-ss", f"{skew:.6f}", "-i", apath,
                 "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
                 "-t", f"{end - start:.6f}", "-muxdelay", "0", "-muxpreload", "0",
                 "-output_ts_offset", f"{start:.6f}", "-f", "mpegts", "pipe:1"],
                capture_output=True)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode()[:200])
        return proc.stdout


class Library:
    def __init__(self):
        self.videos = {}
        self.segments = OrderedDict()
        self.building = {}
        self.bytes = 0
        self.lock = threading.Lock()

    def prepare(self, page, height):
        # the cap is part of the identity, a different height is a different video
        key = hashlib.sha256(f"{page}|{height}".encode()).hexdigest()[:16]
        with self.lock:
            video = self.videos.get(key)
        if video is None:
            began = time.time()
            video = Video(page, height)
            with self.lock:
                self.videos[key] = video
            log(f"prepared {key} {video.video['id']} {video.video['h']}p "
                f"{len(video.segments)} segments in {time.time() - began:.1f}s {page}")
        return key

    def playlist(self, key, base):
        return self.videos[key].playlist(base, key)

    def segment(self, key, index):
        name = f"{key}/{index}"
        with self.lock:
            if name in self.segments:
                self.segments.move_to_end(name)
                return self.segments[name]
            # the player reissues requests it already has in flight
            building = self.building.setdefault(name, threading.Lock())

        with building:
            with self.lock:
                if name in self.segments:
                    return self.segments[name]
            began = time.time()
            data = self.videos[key].segment(index)
            log(f"  {name}: {len(data) // 1024}KB in {time.time() - began:.2f}s")
            with self.lock:
                self.segments[name] = data
                self.bytes += len(data)
                while self.bytes > CACHE_BYTES and len(self.segments) > 1:
                    _, dropped = self.segments.popitem(last=False)
                    self.bytes -= len(dropped)
                self.building.pop(name, None)
            return data


LIBRARY = Library()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        try:
            if url.path == "/prepare":
                query = urllib.parse.parse_qs(url.query)
                page = query.get("url", [""])[0]
                asked = query.get("maxheight", [""])[0]
                height = min(int(asked), MAX_HEIGHT) if asked.isdigit() else MAX_HEIGHT
                key = LIBRARY.prepare(page, height)
                self.reply(f"http://{self.headers['Host']}/v/{key}/index.m3u8\n".encode(),
                           "text/plain")
            elif (m := re.fullmatch(r"/v/([0-9a-f]+)/index\.m3u8", url.path)):
                base = f"http://{self.headers['Host']}"
                self.reply(LIBRARY.playlist(m.group(1), base),
                           "application/vnd.apple.mpegurl")
            elif (m := re.fullmatch(r"/v/([0-9a-f]+)/seg(\d+)\.ts", url.path)):
                self.reply(LIBRARY.segment(m.group(1), int(m.group(2))), "video/mp2t")
            else:
                self.send_error(404)
        except Unsupported as e:
            # 409 marks the cases worth telling someone about
            note = "" if e.expected else " (unexpected)"
            log(f"cannot remux{note}: {e}")
            self.send_response(204 if e.expected else 409)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass  # media foundation drops transfers mid-write as a matter of course
        except KeyError:
            self.send_error(404)
        except Exception as e:
            log(f"error on {url.path}: {type(e).__name__}: {e}")
            self.send_error(500)


log(f"listening on 127.0.0.1:{PORT}")
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
