#!/usr/bin/env python3
"""Tiny snapshot server for the auto-renewing RDP chain.

Runs on the persistent storage VPS, listens only on the Tailscale interface.
The Windows session uploads one tar.gz of its desktop, the next session
downloads it again. Standard library only, no dependencies.

Endpoints
  GET  /health         -> {"ok": true, ...}
  GET  /meta           -> info about the current snapshot
  GET  /stats          -> sizes of every retained snapshot
  GET  /marker         -> the small last-save.txt sent with the snapshot
  GET  /snapshot       -> the current snapshot (tar.gz)
  PUT  /snapshot       -> upload a new snapshot (rotates the old ones)
                          headers: X-Snapshot-Format, X-Snapshot-Sha256,
                                   X-Snapshot-Sha-Algorithm, X-Session-Number
  GET  /snapshot/<n>   -> snapshot n (0 = newest)

Auth: if SYNC_TOKEN is set, every request must send "Authorization: Bearer <token>".
Storage: SNAP_DIR (default /mnt/vpsmajani); keeps SNAP_KEEP snapshots.
"""

import json
import os
import shutil
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SNAP_DIR = os.environ.get("SNAP_DIR", "/mnt/vpsmajani")
SNAP_KEEP = max(1, int(os.environ.get("SNAP_KEEP", "3")))
SNAP_ROOT = os.environ.get("SNAP_ROOT", SNAP_DIR)
SNAP_PREFIX = "snapshot"
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(4 * 1024**3)))
TOKEN = os.environ.get("SYNC_TOKEN", "")
BIND = os.environ.get("BIND_ADDR", "0.0.0.0")
PORT = int(os.environ.get("BIND_PORT", "8787"))

META = os.path.join(SNAP_DIR, "meta.json")


def snap_path(n):
    return os.path.join(SNAP_DIR, f"{SNAP_PREFIX}-{n}.tar.gz")


def detect_format(path):
    """Sniff what the client actually sent, so a mislabelled file cannot
    poison the volume. Returns a format name or None if unrecognised."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(512)
            fh.seek(257)
            tar_magic = fh.read(5)
    except OSError:
        return None

    if head[:2] == b"\x1f\x8b":
        return "tar.gz"
    if head[:6] == b"7z\xbc\xaf'\x1c":
        return "7z"
    if head[:4] == b"PK\x03\x04":
        return "zip"
    if tar_magic == b"ustar":
        return "tar"
    return None


def read_meta():
    try:
        with open(META, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write_meta(meta):
    tmp = META + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, META)


def newest_index():
    for n in range(SNAP_KEEP):
        if os.path.exists(snap_path(n)):
            return n
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "vpsmajani-sync/1.0"
    protocol_version = "HTTP/1.1"

    # ---- helpers ---------------------------------------------------------
    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, indent=2) + "\n")

    def _authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # ---- routing ---------------------------------------------------------
    def do_GET(self):
        if not self._authorized():
            return self._json(401, {"error": "unauthorized"})

        path = self.path.split("?")[0]

        if path == "/health":
            return self._json(200, {"ok": True, "keep": SNAP_KEEP, "dir": SNAP_DIR})

        if path == "/meta":
            meta = read_meta()
            if not meta:
                return self._json(404, {"error": "no snapshot yet"})
            return self._json(200, meta)

        if path == "/stats":
            out = {}
            total = 0
            for n in range(SNAP_KEEP):
                p = snap_path(n)
                if os.path.exists(p):
                    size = os.path.getsize(p)
                    total += size
                    out[os.path.basename(p)] = {"bytes": size, "mtime": int(os.path.getmtime(p))}
            return self._json(200, {"snapshots": out, "total_bytes": total})

        if path == "/marker":
            marker = os.path.join(SNAP_DIR, "last-save.txt")
            if not os.path.exists(marker):
                return self._json(404, {"error": "no marker yet"})
            with open(marker, "r", encoding="utf-8", errors="replace") as fh:
                return self._send(200, fh.read(), "text/plain; charset=utf-8")

        if path == "/snapshot":
            n = newest_index()
            if n is None:
                return self._json(404, {"error": "no snapshot yet"})
            return self._serve_file(snap_path(n))

        if path.startswith("/snapshot/"):
            try:
                n = int(path.rsplit("/", 1)[1])
            except ValueError:
                return self._json(400, {"error": "bad index"})
            if not 0 <= n < SNAP_KEEP or not os.path.exists(snap_path(n)):
                return self._json(404, {"error": "no such snapshot"})
            return self._serve_file(snap_path(n))

        return self._json(404, {"error": "not found"})

    def _serve_file(self, full):
        size = os.path.getsize(full)
        meta = read_meta()
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(size))
        self.send_header("X-Snapshot-Bytes", str(size))
        self.send_header("X-Snapshot-Time", str(meta.get("saved_at", "")))
        self.end_headers()
        with open(full, "rb") as fh:
            shutil.copyfileobj(fh, self.wfile, 1024 * 256)

    def do_PUT(self):
        if not self._authorized():
            return self._json(401, {"error": "unauthorized"})
        if self.path.split("?")[0] == "/marker":
            return self._put_marker()
        if self.path.split("?")[0] != "/snapshot":
            return self._json(404, {"error": "not found"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._json(400, {"error": "bad Content-Length"})

        if length <= 0:
            return self._json(400, {"error": "empty body"})
        if length > MAX_BYTES:
            return self._json(413, {"error": "too large", "max_bytes": MAX_BYTES})

        os.makedirs(SNAP_DIR, exist_ok=True)
        incoming = os.path.join(SNAP_DIR, f".{SNAP_PREFIX}-incoming.tmp")

        remaining = length
        with open(incoming, "wb") as fh:
            while remaining > 0:
                chunk = self.rfile.read(min(1024 * 256, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
            fh.flush()
            os.fsync(fh.fileno())

        if remaining != 0:
            try:
                os.unlink(incoming)
            except OSError:
                pass
            return self._json(400, {"error": "incomplete upload"})

        # Only store something we can recognise (and therefore restore).
        detected = detect_format(incoming)
        if not detected:
            os.unlink(incoming)
            return self._json(415, {"error": "unrecognised archive format"})
        format_name = detected

        # Rotate: snapshot-N -> snapshot-(N+1), newest first.
        rotating = [n for n in range(SNAP_KEEP) if os.path.exists(snap_path(n))]
        for n in sorted(rotating, reverse=True):
            if n + 1 < SNAP_KEEP:
                os.replace(snap_path(n), snap_path(n + 1))
        os.replace(incoming, snap_path(0))

        marker = os.path.join(SNAP_DIR, "last-save.txt")
        origin = {}
        if os.path.exists(marker):
            try:
                with open(marker, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if "=" in line:
                            k, v = line.strip().split("=", 1)
                            origin[k] = v
            except OSError:
                pass

        meta = {
            "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "bytes": os.path.getsize(snap_path(0)),
            "client": self.headers.get("X-Client-Name", "unknown"),
            "session": self.headers.get("X-Session-Number", "unknown"),
            "format": format_name,
            "sha256": self.headers.get("X-Snapshot-Sha256", ""),
            "sha_algorithm": self.headers.get("X-Snapshot-Sha-Algorithm", "sha256"),
            "origin": origin,
        }
        write_meta(meta)
        return self._json(201, {"ok": True, **meta})

    def _put_marker(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._json(400, {"error": "bad Content-Length"})
        if not 0 < length <= 64 * 1024:
            return self._json(400, {"error": "marker too big or empty"})

        os.makedirs(SNAP_DIR, exist_ok=True)
        body = self.rfile.read(length)
        with open(os.path.join(SNAP_DIR, "last-save.txt"), "wb") as fh:
            fh.write(body)
        return self._json(201, {"ok": True, "bytes": len(body)})

    def do_DELETE(self):
        if not self._authorized():
            return self._json(401, {"error": "unauthorized"})
        for n in range(SNAP_KEEP):
            try:
                os.unlink(snap_path(n))
            except OSError:
                pass
        try:
            os.unlink(META)
        except OSError:
            pass
        return self._json(200, {"ok": True, "cleared": True})


def main():
    os.makedirs(SNAP_DIR, exist_ok=True)
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"vpsmajani-sync listening on {BIND}:{PORT}, dir={SNAP_DIR}, keep={SNAP_KEEP}, auth={'on' if TOKEN else 'off'}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
