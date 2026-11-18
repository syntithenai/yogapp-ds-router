#!/usr/bin/env bash
# Install yogapp-ds-router, its helpers, and (if available) a systemd user unit.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
CONFIG_DIR="${YOGAPP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/yogapp}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yogapp-ds-router"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_NAME="yogapp-ds-router.service"
INSTALL_SERVICE=1
PYTHON="${PYTHON:-}"

for arg in "$@"; do
  case "$arg" in
    --no-service) INSTALL_SERVICE=0 ;;
    --prefix=*) PREFIX="${arg#*=}" ;;
    --python=*) PYTHON="${arg#*=}" ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
      echo "usage: $0 [--no-service] [--prefix=DIR] [--python=PATH]"
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- interpreter
# The router needs aiohttp. Prefer an interpreter that already has it, else
# build a private venv (distro pythons are often PEP-668 "externally managed").
has_aiohttp() { "$1" -c 'import aiohttp' >/dev/null 2>&1; }

pick_python() {
  if [[ -n "$PYTHON" ]]; then
    if has_aiohttp "$PYTHON"; then echo "$PYTHON"; return 0; fi
    echo "note: $PYTHON lacks aiohttp; will try a venv" >&2
  fi
  for cand in python3 python3.13 python3.12 python3.11 python3.10; do
    if have "$cand" && has_aiohttp "$(command -v "$cand")"; then
      command -v "$cand"; return 0
    fi
  done
  if have python3; then
    say "creating private venv at $DATA_DIR/venv (python3 has no aiohttp)"
    mkdir -p "$DATA_DIR"
    python3 -m venv "$DATA_DIR/venv"
    "$DATA_DIR/venv/bin/python" -m pip install --quiet --upgrade pip
    "$DATA_DIR/venv/bin/python" -m pip install --quiet -r "$REPO_DIR/requirements.txt"
    echo "$DATA_DIR/venv/bin/python"; return 0
  fi
  echo "error: python3 not found" >&2
  return 1
}

if [[ -n "$PYTHON" ]] && ! has_aiohttp "$PYTHON" && [[ -x "$PYTHON" ]]; then
  "$PYTHON" -m pip install --quiet -r "$REPO_DIR/requirements.txt" 2>/dev/null || true
fi
PY="$(pick_python)" || exit 1
say "interpreter: $PY ($("$PY" -c 'import aiohttp,sys; print("aiohttp", aiohttp.__version__, "on", sys.version.split()[0])'))"

# -------------------------------------------------------------------- scripts
say "installing scripts into $PREFIX"
mkdir -p "$PREFIX"
for f in yogapp-ds-router yogapp-agent-config cc-ds; do
  install -m 0755 "$REPO_DIR/bin/$f" "$PREFIX/$f"
  echo "  $PREFIX/$f"
done

# ----------------------------------------------------------------------- keys
if [[ ! -f "$CONFIG_DIR/agent.env" ]]; then
  mkdir -p "$CONFIG_DIR"
  install -m 0600 "$REPO_DIR/agent.env.example" "$CONFIG_DIR/agent.env"
  echo
  echo "  created $CONFIG_DIR/agent.env — add your DEEPSEEK_API_KEY before use."
else
  chmod 600 "$CONFIG_DIR/agent.env" 2>/dev/null || true
  echo "  keeping existing $CONFIG_DIR/agent.env"
fi

# --------------------------------------------------------------------- systemd
if [[ "$INSTALL_SERVICE" -eq 1 ]]; then
  if [[ -d /run/systemd/system ]] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    say "installing systemd user unit"
    mkdir -p "$UNIT_DIR"
    sed "s|@PYTHON@|$PY|g" "$REPO_DIR/systemd/$UNIT_NAME.in" > "$UNIT_DIR/$UNIT_NAME"
    echo "  $UNIT_DIR/$UNIT_NAME"
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME"

    printf '  waiting for health'
    ok=0
    for _ in $(seq 1 20); do
      if curl -sf -m 1 "http://127.0.0.1:18787/health" >/dev/null 2>&1; then ok=1; break; fi
      printf '.'; sleep 0.5
    done
    echo
    if [[ "$ok" -eq 1 ]]; then
      curl -s "http://127.0.0.1:18787/health"; echo
    else
      echo "  warning: no /health response yet — check:" >&2
      echo "    journalctl --user -u $UNIT_NAME -n 40 --no-pager" >&2
    fi

    if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo no)" != "yes" ]]; then
      echo
      echo "  note: lingering is off, so the proxy starts at login rather than boot."
      echo "  enable boot start with: sudo loginctl enable-linger $(id -un)"
    fi
  else
    say "systemd user session not available — skipping service install"
    echo "  run it manually: $PREFIX/yogapp-ds-router --daemon"
  fi
fi

# ------------------------------------------------------------------------ next
say "next steps"
cat <<EOF
  1. Add your key:   \$EDITOR $CONFIG_DIR/agent.env      (DEEPSEEK_API_KEY=...)
  2. Configure:      $PREFIX/yogapp-agent-config
  3. Reload the VS Code window (or fully quit and reopen Claude Code)
  4. Verify:         curl -s http://127.0.0.1:18787/health

  service:  systemctl --user status yogapp-ds-router
  logs:     journalctl --user -u yogapp-ds-router -f
EOF
