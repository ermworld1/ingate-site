#!/usr/bin/env bash
# Install ingatecapital.com on this droplet, beside whatever Caddy already serves.
#
#   sudo bash install.sh
#
# Idempotent: safe to run again. It backs up /etc/caddy/Caddyfile before
# touching it, runs `caddy validate` before reloading, and leaves every other
# site on this droplet alone.
#
#   /var/www/ingatecapital                  the site
#   /opt/ingate/ingate-beta.py              the beta endpoint
#   /etc/ingate/beta.env                    its config (created once, never overwritten)
#   /var/lib/ingate/signups.csv             the signups
#   /etc/caddy/sites/ingatecapital.caddy    the vhost

set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBROOT=/var/www/ingatecapital
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
command -v caddy >/dev/null || { echo "caddy not found on this droplet"; exit 1; }
[ -f "$SRC/index.html" ] || { echo "index.html missing next to install.sh"; exit 1; }
[ -f "$SRC/og.png" ]     || { echo "og.png missing next to install.sh"; exit 1; }

say "Service account and directories"
id -u ingate >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ingate
install -d -m 755 "$WEBROOT" /opt/ingate /etc/caddy/sites /var/log/caddy /etc/ingate
install -d -m 700 -o ingate -g ingate /var/lib/ingate

say "Site files"
install -m 644 "$SRC/index.html" "$WEBROOT/index.html"
install -m 644 "$SRC/og.png"     "$WEBROOT/og.png"
chown -R caddy:caddy "$WEBROOT" 2>/dev/null || true
echo "    index.html $(stat -c%s "$WEBROOT/index.html") bytes, og.png $(stat -c%s "$WEBROOT/og.png") bytes"

say "Beta endpoint"
cat > /opt/ingate/ingate-beta.py <<'INGATE_EOF_SERVICE'
#!/usr/bin/env python3
"""
Beta signup endpoint for ingatecapital.com.

The Bluehost build ran this as PHP under Apache. On the droplet it runs as a
small stdlib-only service behind Caddy, which reverse-proxies /api/beta here.

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
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDRESS = re.compile(r"^0x[a-fA-F0-9]{40}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

STORE = os.environ.get("INGATE_STORE", "/var/lib/ingate/signups.csv")
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

    do_HEAD = do_PUT = do_DELETE = do_PATCH = _not_allowed

    def do_GET(self):
        if not self.path.startswith("/api/beta"):
            return self._send(404, {"ok": False, "error": "not_found"})
        s = sinks_available()
        any_ = any(s.values())
        self._send(200 if any_ else 503, {"ok": any_, "sinks": s})

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
    bind = os.environ.get("INGATE_BIND", "127.0.0.1:8787")
    host, _, port = bind.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    srv.daemon_threads = True
    sys.stderr.write("ingate-beta listening on %s store=%s\n" % (bind, STORE))
    srv.serve_forever()


if __name__ == "__main__":
    main()
INGATE_EOF_SERVICE
chmod 755 /opt/ingate/ingate-beta.py
python3 -m py_compile /opt/ingate/ingate-beta.py

cat > /etc/systemd/system/ingate-beta.service <<'INGATE_EOF_UNIT'
[Unit]
Description=Ingate beta signup endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ingate/ingate-beta.py
EnvironmentFile=-/etc/ingate/beta.env
User=ingate
Group=ingate
Restart=always
RestartSec=3

# it only ever needs its own state directory
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ingate
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
INGATE_EOF_UNIT

if [ ! -f /etc/ingate/beta.env ]; then
  cat > /etc/ingate/beta.env <<'INGATE_EOF_ENV'
# Copy to /etc/ingate/beta.env and fill in what you want to use.
# Leave a value empty to turn that sink off. chmod 600 — it holds a token.

INGATE_STORE=/var/lib/ingate/signups.csv
INGATE_RATE_PER_HOUR=20
INGATE_BIND=127.0.0.1:8787

# Signups reach your phone the moment they happen.
#   1. Message @BotFather, send /newbot, copy the token.
#   2. Message the bot once, open https://api.telegram.org/bot<TOKEN>/getUpdates
#      and copy chat.id.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

DISCORD_WEBHOOK_URL=
INGATE_EOF_ENV
  chmod 600 /etc/ingate/beta.env
  echo "    created /etc/ingate/beta.env (Telegram off until you fill it in)"
else
  echo "    kept the existing /etc/ingate/beta.env"
fi

systemctl daemon-reload
systemctl enable --now ingate-beta.service
sleep 1
systemctl is-active --quiet ingate-beta.service || { systemctl status --no-pager -l ingate-beta.service; exit 1; }
echo "    ingate-beta is active"

say "Caddy vhost"
cat > /etc/caddy/sites/ingatecapital.caddy <<'INGATE_EOF_CADDY'
# ingatecapital.com — static site + the beta signup endpoint.
# Caddy obtains and renews the TLS certificate on its own, once the domain's
# A record points at this droplet.

www.ingatecapital.com {
	redir https://ingatecapital.com{uri} permanent
}

ingatecapital.com {
	encode zstd gzip
	root * /var/www/ingatecapital

	# the page posts here; the service listens on loopback only
	handle /api/beta* {
		reverse_proxy 127.0.0.1:8787
	}

	handle {
		try_files {path} /index.html
		file_server
	}

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		X-Frame-Options "SAMEORIGIN"
		-Server
	}
	header /index.html Cache-Control "public, max-age=0, must-revalidate"
	header /og.png    Cache-Control "public, max-age=604800"

	log {
		output file /var/log/caddy/ingatecapital.log {
			roll_size 10mb
			roll_keep 5
		}
	}
}
INGATE_EOF_CADDY

if ! grep -qE '^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\*' /etc/caddy/Caddyfile 2>/dev/null; then
  cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
  printf '\n# added for ingatecapital.com\nimport /etc/caddy/sites/*.caddy\n' >> /etc/caddy/Caddyfile
  echo "    added the import line (previous Caddyfile backed up)"
else
  echo "    Caddyfile already imports /etc/caddy/sites"
fi

say "Validate and reload"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy || systemctl restart caddy

say "Check"
printf '    endpoint  '; curl -fsS http://127.0.0.1:8787/api/beta || echo FAILED
printf '\n    page      '
if curl -fsS -o /tmp/ig.check -w 'HTTP %{http_code}  %{size_download} bytes\n' -H 'Host: ingatecapital.com' http://127.0.0.1/ ; then
  grep -q 'Ingate' /tmp/ig.check && echo "    content looks right" || echo "    served, but content unexpected"
  rm -f /tmp/ig.check
else
  echo "    (not served locally yet - normal until DNS points here)"
fi

cat <<'DONE'

Server side is done.

The site goes live once ingatecapital.com and www point at this droplet.
Caddy issues the TLS certificate by itself within seconds of the first
request on the real hostname.

To send signups to Telegram: fill /etc/ingate/beta.env, then
  systemctl restart ingate-beta
DONE
