# ingatecapital.com

The site and the small service that runs it.

| file | what it is |
|---|---|
| `index.html` | the whole site, one file |
| `og.png` | link preview image |
| `server.py` | serves the page and the `/api/beta` signup endpoint, stdlib only |
| `Procfile` | how the platform starts it |
| `install.sh` | alternative: install onto a server that already runs Caddy |

## The beta endpoint

`POST /api/beta` with `{"address":"0x…","score":88.9,"source":"wallet_check"}`.
The page reads status codes, not message text:

| code | meaning |
|---|---|
| 200 | stored |
| 200 + `duplicate` | already on the list |
| 400 | not a valid address |
| 429 | more than 20 posts/hour from one IP |
| 502 | a sink was configured but the write failed |
| 503 | nothing configured — it never fakes a success |

### Configuration

All optional, all via environment variables:

| variable | effect |
|---|---|
| `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | signups arrive as chat messages |
| `DISCORD_WEBHOOK_URL` | signups arrive in a channel |
| `INGATE_STORE` | path to a CSV; only useful where the disk survives a restart |
| `INGATE_RATE_PER_HOUR` | per-IP POST cap, default 20, `0` disables |

With none of them set the endpoint answers 503 and the page says plainly that
nothing was sent.

**On a platform without persistent disk**, leave `INGATE_STORE` empty and use
Telegram. A CSV written to the container filesystem is wiped on every deploy
and restart, which would quietly lose signups.

### Getting a Telegram token

1. Message `@BotFather`, send `/newbot`, copy the token.
2. Message the new bot once, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `chat.id`.
