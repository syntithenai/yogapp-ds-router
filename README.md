# yogapp-ds-router

An Anthropic-compatible HTTP proxy that lets **Claude Code** (CLI and the VS Code
panel) run on **DeepSeek**, with images, PDFs and Kimi/Moonshot support.

Claude Code only speaks the Anthropic Messages API. DeepSeek publishes an
Anthropic-compatible endpoint, so pointing `ANTHROPIC_BASE_URL` at it mostly
works — except for the things this proxy adds:

| Problem with DeepSeek's endpoint directly | What the proxy does |
|---|---|
| No image input | Re-routes image turns to a vision model (`deepseek-flash`) |
| No PDF/document blocks | Extracts text from text PDFs; renders scanned pages to images |
| Model names leak Anthropic tiers (`opus`/`sonnet`) | Rewrites every tier to `deepseek-flash` |
| Kimi/Moonshot needs a different host and key | Routes `kimi*` models to Moonshot automatically |
| LM Studio has no Anthropic endpoint | Routes `local/...` models to LM Studio on `:1234` |
| No cost visibility by tier | Flash-only by default, so a stray "Opus" tab cannot burn Pro spend |

```
Claude Code  ──▶  http://127.0.0.1:18787  ──▶  api.deepseek.com/anthropic
(Anthropic API)        this proxy            image/PDF → vision model
                                              kimi*     → api.moonshot.ai
                                              local/*   → LM Studio :1234
```

Everything binds to **127.0.0.1** only. Your API key never leaves your machine
except as the `Authorization` header toward the upstream API you configured.

## Why "flash-only"

`deepseek-flash` is cheaper and, for the workloads this was built for, benchmarks
no worse than `deepseek-v4-pro`. The proxy therefore rewrites even an explicit
`deepseek-v4-pro` request to Flash. Set `YOGAPP_DS_ALLOW_PRO=1` to restore the
old Pro-primary behaviour with drift escalation.

## Requirements

- Python 3.10+ with [`aiohttp`](requirements.txt) (the installer builds a private
  venv if your system Python has no `aiohttp`)
- [Claude Code](https://claude.com/claude-code) (CLI or VS Code extension)
- Optional: a systemd user session (Linux) for always-on operation
- A DeepSeek API key with credit — <https://platform.deepseek.com>

## Install

```bash
git clone https://github.com/syntithenai/yogapp-ds-router.git
cd yogapp-ds-router
./install.sh
```

That installs `yogapp-ds-router`, `yogapp-agent-config` and `cc-ds` into
`~/.local/bin`, creates `~/.config/yogapp/agent.env` (mode 600) if missing, and
— where a systemd user session exists — installs and starts
`yogapp-ds-router.service` with automatic restart.

Then:

```bash
$EDITOR ~/.config/yogapp/agent.env   # set DEEPSEEK_API_KEY
yogapp-agent-config                  # point Claude Code at the proxy
curl -s http://127.0.0.1:18787/health
```

Reload the VS Code window (or fully quit and reopen Claude Code) so the extension
re-reads its settings.

Non-systemd / manual:

```bash
yogapp-ds-router            # foreground, logs to the terminal
yogapp-ds-router --daemon   # background, logs to ~/.cache/yogapp/ds-router.log
yogapp-ds-router --stop
```

`install.sh` flags: `--no-service`, `--prefix=DIR`, `--python=PATH`.

## Always-on with systemd

`./install.sh` does this for you; the pieces are:

```bash
systemctl --user enable --now yogapp-ds-router
systemctl --user status yogapp-ds-router
journalctl --user -u yogapp-ds-router -f
```

The unit runs the script in the **foreground** (`Type=simple`) because `--daemon`
double-forks and owns a pidfile — two things systemd should own instead. It uses
`Restart=always` with `StartLimitIntervalSec=0` so it is never rate-limited into
staying down.

The unit template is [`systemd/yogapp-ds-router.service.in`](systemd/yogapp-ds-router.service.in);
`@PYTHON@` is replaced with the interpreter that has `aiohttp` at install time.

To start at boot without logging in, enable lingering once:

```bash
sudo loginctl enable-linger "$USER"
```

### Why the unit must use an absolute interpreter

Under systemd, `PATH` is minimal (`/usr/local/bin:/usr/bin:/bin`). A
`#!/usr/bin/env python3` shebang therefore resolves to the distro Python, which
usually has no `aiohttp` — the service would crash-loop. The installer pins the
interpreter it verified.

Do **not** mix `--daemon` with the unit: a detached daemon would compete for
port 18787 and leave a stale pidfile behind.

## Configuration

All settings are environment variables (also readable from
`~/.config/yogapp/agent.env`, which the router parses itself).

| Variable | Default | Purpose |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | **Required.** Upstream credential |
| `MOONSHOT_API_KEY` | — | Optional; enables `kimi*` models |
| `LMSTUDIO_API_KEY` | `lm-studio` | Key sent to LM Studio |
| `YOGAPP_DS_ROUTER_HOST` | `127.0.0.1` | Bind address (keep it loopback) |
| `YOGAPP_DS_ROUTER_PORT` | `18787` | Bind port |
| `YOGAPP_DS_UPSTREAM` | `https://api.deepseek.com/anthropic` | DeepSeek-compatible upstream |
| `YOGAPP_MS_UPSTREAM` | `https://api.moonshot.ai/anthropic` | Moonshot upstream |
| `YOGAPP_LOCAL_UPSTREAM` | `http://127.0.0.1:1234` | LM Studio base URL |
| `YOGAPP_DS_PRIMARY_MODEL` | `deepseek-flash` | Default text model |
| `YOGAPP_DS_VISION_MODEL` | `deepseek-flash` | Model used for images/PDF pages |
| `YOGAPP_DS_ALLOW_PRO` | `0` | `1` re-enables Pro + escalation |
| `YOGAPP_DS_MAX_PDF_PAGES` | `20` | Page cap when rendering a PDF |
| `YOGAPP_DS_ROUTER_URL` | `http://127.0.0.1:18787` | What Claude Code targets |
| `YOGAPP_AGENT_ENV` | `~/.config/yogapp/agent.env` | Secrets file location |
| `YOGAPP_DS_ROUTER_PID` / `_LOG` | `~/.cache/yogapp/…` | Pidfile/log for `--daemon` |

## Endpoints

| Route | Behaviour |
|---|---|
| `POST /v1/messages` | The proxy path — forwards to the routed upstream |
| `GET /health` | JSON: `ok`, upstreams, `kimi_configured`, `primary`, `vision`, `flash_only` |
| anything else | Passed through to the DeepSeek upstream |

## Security model

- Keys live only in `~/.config/yogapp/agent.env` (mode 600) and in your local
  Claude settings file (mode 600). **No key is stored in this repository.**
- The proxy listens on loopback only. Do not expose it to a network: it forwards
  whatever `Authorization` header it is given.
- `~/.claude/settings.json` contains your key in `ANTHROPIC_AUTH_TOKEN`; it is
  written `0600` by `yogapp-agent-config`.
- The proxy keeps no request log in the `systemd` setup; logs go to journald.
  In `--daemon` mode requests are appended to `~/.cache/yogapp/ds-router.log`.

## Limitations

- Anthropic `cache_control` breakpoints are ignored. DeepSeek uses automatic
  prefix caching instead (stable prefixes are cheap, new tokens are not).
- Anthropic-only features (batch API, some beta headers) are passed through
  untouched and may be rejected upstream.
- The proxy assumes the upstream implements Anthropic's `/v1/messages` shape.
- Not affiliated with Anthropic, DeepSeek or Moonshot.

## Repository layout

```
bin/yogapp-ds-router          the proxy (stdlib + aiohttp only)
bin/yogapp-agent-config       writes Claude Code's settings.json env block
bin/cc-ds                     terminal launcher through the proxy
systemd/*.service.in          systemd user unit template
install.sh                    installer (venv fallback, service, health check)
agent.env.example             secrets template — the only env file tracked
```

## License

MIT — see [LICENSE](LICENSE).
