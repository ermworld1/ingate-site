#!/usr/bin/env python3
"""
ingatecapital.com on DigitalOcean App Platform.

Serves the static page and the beta signup endpoint from one process, because
App Platform gives a container a port rather than a web server.

The Bluehost build ran the endpoint as PHP under Apache. Here it is stdlib-only
Python: no packages to install, no web server to configure.

App Platform has no persistent disk, so the CSV store is scratch space that is
wiped on every deploy and restart. Telegram is the sink that actually keeps a
record; with nothing configured the endpoint returns 503 rather than pretending
it saved an address.

The status-code contract is identical to the PHP version, because index.html
reads codes rather than message text:

  200 {ok:true}                      stored
  200 {ok:true, duplicate:true}      already on the list
  400 {ok:false, error:invalid_address}
  429 {ok:false, error:rate_limited}
  502 {ok:false, error:sink_failed}
  503 {ok:false, error:no_sink_configured}

It never reports success when nothing was written.

Config comes from the environment (see /etc/ingate/beta.env):
  INGATE_STORE          path to the signup CSV (default /var/lib/ingate/signups.csv)
  INGATE_RATE_PER_HOUR  POSTs accepted per IP per hour (default 20, 0 disables)
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
  DISCORD_WEBHOOK_URL
  INGATE_BIND           default 127.0.0.1:8787
"""

import csv
import io
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDRESS = re.compile(r"^0x[a-fA-F0-9]{40}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

STORE = os.environ.get("INGATE_STORE", "")   # off by default: no persistent disk here
STATIC = os.environ.get("INGATE_STATIC", os.path.dirname(os.path.abspath(__file__)))
RATE = int(os.environ.get("INGATE_RATE_PER_HOUR", "20") or 0)
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TG_CHAT = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
DISCORD = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()

HEADER = ["ts", "address", "email", "score", "source", "ip_hash", "ua"]
_lock = threading.Lock()
_rate = {}          # (ip, hour) -> count


def sinks_available():
    return {
        "store": bool(STORE),
        "telegram": bool(TG_TOKEN and TG_CHAT),
        "discord": bool(DISCORD),
    }


def post_json(url, payload, ok_codes=(200, 204)):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status in ok_codes
    except urllib.error.HTTPError as e:
        return e.code in ok_codes
    except Exception:
        return False


def rate_ok(ip):
    """One counter per IP-hour, swept as it goes so the dict cannot grow forever."""
    if not ip or RATE <= 0:
        return True
    hour = int(time.time() // 3600)
    with _lock:
        for k in [k for k in _rate if k[1] < hour - 1]:
            _rate.pop(k, None)
        key = (ip, hour)
        n = _rate.get(key, 0)
        if n >= RATE:
            return False
        _rate[key] = n + 1
    return True


def store_write(record):
    """Append unless the address is already there. Returns (stored, duplicate)."""
    d = os.path.dirname(STORE)
    if d:
        os.makedirs(d, mode=0o700, exist_ok=True)
    key = record["address"]
    with _lock:
        duplicate = False
        if os.path.exists(STORE):
            with open(STORE, "r", newline="", encoding="utf-8") as fh:
                for row in csv.reader(fh):
                    if len(row) > 1 and row[1].strip().lower() == key:
                        duplicate = True
                        break
        if duplicate:
            return True, True
        fresh = not os.path.exists(STORE) or os.path.getsize(STORE) == 0
        with open(STORE, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if fresh:
                w.writerow(HEADER)
            w.writerow([record[k] for k in HEADER])
        os.chmod(STORE, 0o600)
    return True, False


class Handler(BaseHTTPRequestHandler):
    server_version = "ingate-beta"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):          # keep the journal quiet
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _not_allowed(self):
        # The PHP version answered 405 with an Allow header for anything that
        # was not GET or POST. BaseHTTPRequestHandler would say 501 instead.
        body = json.dumps({"ok": False, "error": "method_not_allowed"}).encode()
        self.send_response(405)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_PUT = do_DELETE = do_PATCH = _not_allowed

    # ---- static side ---------------------------------------------------
    TYPES = {".html": "text/html; charset=utf-8", ".png": "image/png",
             ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8",
             ".svg": "image/svg+xml", ".json": "application/json"}

    def _static(self, head_only=False):
        """Serve a file from STATIC, falling back to index.html like the old
        .htaccess did, so deep links keep working."""
        rel = urllib.parse.urlparse(self.path).path.lstrip("/") or "index.html"
        root = os.path.realpath(STATIC)
        target = os.path.realpath(os.path.join(root, rel))
        # never serve outside the static root
        if not (target == root or target.startswith(root + os.sep)) or not os.path.isfile(target):
            target = os.path.join(root, "index.html")
        if not os.path.isfile(target):
            return self._send(404, {"ok": False, "error": "not_found"})

        ext = os.path.splitext(target)[1].lower()
        ctype = self.TYPES.get(ext, "application/octet-stream")
        cache = ("public, max-age=604800" if ext == ".png"
                 else "public, max-age=0, must-revalidate")
        try:
            with open(target, "rb") as fh:
                body = fh.read()
        except OSError:
            return self._send(500, {"ok": False, "error": "read_failed"})

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_GET(self):
        if not self.path.startswith("/api/beta"):
            return self._static()
        s = sinks_available()
        any_ = any(s.values())
        self._send(200 if any_ else 503, {"ok": any_, "sinks": s})

    def do_HEAD(self):
        if not self.path.startswith("/api/beta"):
            return self._static(head_only=True)
        return self._not_allowed()

    def do_POST(self):
        if not self.path.startswith("/api/beta"):
            return self._send(404, {"ok": False, "error": "not_found"})

        s = sinks_available()
        if not any(s.values()):
            return self._send(503, {"ok": False, "error": "no_sink_configured"})

        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        raw = self.rfile.read(min(n, 64 * 1024)) if n > 0 else b""
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
            if not isinstance(body, dict):
                body = {}
        except Exception:
            body = {}

        address = str(body.get("address") or "").strip()
        if not ADDRESS.match(address):
            return self._send(400, {"ok": False, "error": "invalid_address"})

        ip = self._client_ip()
        if not rate_ok(ip):
            return self._send(429, {"ok": False, "error": "rate_limited"})

        try:
            score = float(body.get("score"))
        except (TypeError, ValueError):
            score = ""
        raw_email = str(body.get("email") or "").strip()[:254]
        email = raw_email.lower() if EMAIL.match(raw_email) else ""
        source = str(body.get("source") or "site")[:40]

        import hashlib
        record = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "address": address.lower(),
            "email": email,
            "score": score,
            "source": source,
            "ip_hash": hashlib.sha1(ip.encode()).hexdigest()[:16],
            "ua": str(self.headers.get("User-Agent") or "")[:200],
        }

        stored, duplicate = [], False
        try:
            if s["store"]:
                ok, duplicate = store_write(record)
                if ok:
                    stored.append("store")
        except Exception as e:
            sys.stderr.write("store failed: %r\n" % (e,))
            return self._send(502, {"ok": False, "error": "sink_failed"})

        if not duplicate:
            line = (
                "Beta request\n%s\n%s%s%s\nhttps://app.hyperliquid.xyz/explorer/address/%s"
                % (
                    record["address"],
                    ("Score %s\n" % score) if score != "" else "",
                    (email + "\n") if email else "",
                    source,
                    record["address"],
                )
            )
            if s["telegram"] and post_json(
                "https://api.telegram.org/bot%s/sendMessage" % TG_TOKEN,
                {"chat_id": TG_CHAT, "text": line, "disable_web_page_preview": True},
            ):
                stored.append("telegram")
            if s["discord"] and post_json(DISCORD, {"content": line}):
                stored.append("discord")

        if not stored and not duplicate:
            return self._send(502, {"ok": False, "error": "sink_failed"})

        self._send(200, {"ok": True, "duplicate": duplicate, "stored": stored})


def main():
    # App Platform hands the container a $PORT and expects 0.0.0.0.
    port = int(os.environ.get("PORT") or os.environ.get("INGATE_PORT") or 8080)
    host = os.environ.get("INGATE_HOST", "0.0.0.0")
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    sys.stderr.write("ingate listening on %s:%d static=%s store=%s sinks=%s\n"
                     % (host, port, STATIC, STORE or "(off)", sinks_available()))
    srv.serve_forever()


if __name__ == "__main__":
    main()
