#!/bin/bash
set -e

# ── apple-music-api service installer ────────────────────────────────────────
# Installs the API server and notification listener as launchd agents.
# Python is installed into a local venv — no global installs, no system pollution.

PLIST_LABEL="com.apple-music-api"
NOTIFY_PLIST_LABEL="com.apple-music-notify"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
NOTIFY_PLIST_DEST="$HOME/Library/LaunchAgents/${NOTIFY_PLIST_LABEL}.plist"
APP_PATH="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PATH="$APP_PATH/.venv"
PORT="${PORT:-8181}"

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo ""
echo -e "${BOLD}apple-music-api installer${RESET}"
echo "──────────────────────────────────────────"

# ── 1. Check macOS ────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo -e "${RED}✗ This server only runs on macOS.${RESET}"
  exit 1
fi
echo -e "${GREEN}✓${RESET} macOS detected"

# ── 2. Check Node.js ──────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  echo -e "${RED}✗ Node.js is not installed.${RESET}"
  echo ""
  echo "  Install it from: https://nodejs.org"
  echo "  Or with Homebrew: brew install node"
  exit 1
fi
NODE_MAJOR=$(node -e "console.log(parseInt(process.versions.node.split('.')[0]))")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  echo -e "${RED}✗ Node.js 18+ required (found $(node -v)).${RESET}"
  echo ""
  echo "  Upgrade from: https://nodejs.org"
  exit 1
fi
NODE_BIN="$(which node)"
echo -e "${GREEN}✓${RESET} Node.js $(node -v) detected"

# ── 3. Find Python 3.10+ ──────────────────────────────────────────────────────
echo ""
echo "Checking for Python 3.10+..."

PYTHON_BIN=""
for candidate in \
  /opt/homebrew/bin/python3 \
  /usr/local/bin/python3 \
  /opt/local/bin/python3 \
  /opt/local/bin/python3.14 \
  /opt/local/bin/python3.13 \
  /opt/local/bin/python3.12 \
  /opt/local/bin/python3.11 \
  /opt/local/bin/python3.10 \
  /usr/local/bin/python3.14 \
  /usr/local/bin/python3.13 \
  /usr/local/bin/python3.12 \
  /usr/local/bin/python3.11 \
  /usr/local/bin/python3.10 \
  python3.14 \
  python3.13 \
  python3.12 \
  python3.11 \
  python3.10 \
  python3; do
  if command -v "$candidate" &>/dev/null; then
    ver=$("$candidate" -c "import sys; print(sys.version_info.major * 100 + sys.version_info.minor)" 2>/dev/null || echo 0)
    if [[ "$ver" -ge 310 ]]; then
      PYTHON_BIN="$(command -v "$candidate")"
      break
    fi
  fi
done

# Not found — offer Homebrew install
if [[ -z "$PYTHON_BIN" ]]; then
  echo -e "${YELLOW}⚠ Python 3.10+ not found.${RESET}"
  echo ""
  echo "  Python is required for instant track-change notifications."
  echo "  We can install it automatically via Homebrew."
  echo ""
  read -r -p "  Install Python via Homebrew? [Y/n] " choice
  choice="${choice:-Y}"
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    if ! command -v brew &>/dev/null; then
      echo "  Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to PATH for Apple Silicon
      [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    echo "  Installing Python..."
    brew install python3
    PYTHON_BIN="$(brew --prefix)/bin/python3"
  else
    echo -e "${YELLOW}  Skipping Python install.${RESET}"
    echo "  Instant notifications will not be available."
    echo "  Install Python 3.10+ later and re-run: npm run install-service"
  fi
fi

if [[ -n "$PYTHON_BIN" ]]; then
  echo -e "${GREEN}✓${RESET} $("$PYTHON_BIN" --version) at $PYTHON_BIN"
fi

# ── 4. Set up Python venv and install pyobjc ──────────────────────────────────
if [[ -n "$PYTHON_BIN" ]]; then
  echo ""
  echo "Setting up Python environment..."

  if [[ ! -d "$VENV_PATH" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_PATH"
    echo -e "${GREEN}✓${RESET} Python venv created at .venv/"
  else
    echo -e "${GREEN}✓${RESET} Python venv already exists"
  fi

  VENV_PYTHON="$VENV_PATH/bin/python3"
  VENV_PIP="$VENV_PATH/bin/pip"

  "$VENV_PIP" install --upgrade pip --quiet

  if "$VENV_PYTHON" -c "import Foundation" &>/dev/null 2>&1; then
    echo -e "${GREEN}✓${RESET} pyobjc already installed"
  else
    echo "  Installing pyobjc-framework-Cocoa (this may take a minute)..."
    "$VENV_PIP" install pyobjc-framework-Cocoa --quiet
    echo -e "${GREEN}✓${RESET} pyobjc installed"
  fi
fi

# ── 5. npm install ────────────────────────────────────────────────────────────
echo ""
echo "Installing Node.js dependencies..."
cd "$APP_PATH"
npm install --omit=dev --silent

# Ensure sharp is installed — native module that can go missing after Node upgrades
if ! node -e "require('sharp')" &>/dev/null 2>&1; then
  echo "  Installing sharp (native image module)..."
  npm install sharp --silent
  echo -e "${GREEN}✓${RESET} sharp installed"
else
  echo -e "${GREEN}✓${RESET} sharp already installed"
fi

echo -e "${GREEN}✓${RESET} Dependencies installed"

# ── 6. Create log directory ───────────────────────────────────────────────────
mkdir -p "$APP_PATH/log"
echo -e "${GREEN}✓${RESET} Log directory ready (log/)"

# ── 7. Access control ─────────────────────────────────────────────────────────
# API_KEY, ALLOWED_IPS and HOST come from the environment if set (an empty value
# clears the setting), else from the installed plist, else a prompt (key and IPs).
echo ""
echo "Configuring access control..."

# Print an EnvironmentVariables value from the installed plist (empty if absent)
existing_env() {
  [[ -f "$PLIST_DEST" ]] || return 0
  /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$1" "$PLIST_DEST" 2>/dev/null || true
}

if [[ -n "${API_KEY+x}" ]]; then
  KEY_SOURCE="env"
else
  API_KEY="$(existing_env API_KEY)"
  KEY_SOURCE="existing"
  if [[ -z "$API_KEY" && -t 0 ]]; then
    read -r -p "  Generate an API key to protect the server? [Y/n] " choice || choice=""
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      API_KEY="$(openssl rand -hex 32)"
      KEY_SOURCE="generated"
    fi
  fi
fi
KEY_RE='^[A-Za-z0-9._~+/=-]*$'
if [[ ! "$API_KEY" =~ $KEY_RE ]]; then
  echo -e "${RED}✗ API_KEY may only contain letters, digits and . _ ~ + / = -${RESET}"
  exit 1
fi

if [[ -z "${ALLOWED_IPS+x}" ]]; then
  ALLOWED_IPS="$(existing_env ALLOWED_IPS)"
  if [[ -t 0 ]]; then
    if [[ -n "$ALLOWED_IPS" ]]; then
      read -r -p "  Restrict access to specific IPs/CIDRs (comma-separated, \"none\" = any)? [$ALLOWED_IPS] " ips || ips=""
    else
      read -r -p "  Restrict access to specific IPs/CIDRs (comma-separated, blank = any)? " ips || ips=""
    fi
    [[ -n "$ips" ]] && ALLOWED_IPS="$ips"
    [[ "$ALLOWED_IPS" == "none" ]] && ALLOWED_IPS=""
  fi
fi
IPS_RE='^[0-9a-fA-F:.,/ ]*$'
if [[ ! "$ALLOWED_IPS" =~ $IPS_RE ]]; then
  echo -e "${RED}✗ ALLOWED_IPS may only contain IP addresses, CIDR ranges, commas and spaces.${RESET}"
  exit 1
fi
# Same parser the server uses, so a bad entry fails here instead of at startup
if ! node -e 'try { require(process.argv[1]).parseAllowList(process.argv[2]) } catch (e) { console.error("  " + e.message); process.exit(1) }' \
    "$APP_PATH/lib/access.js" "$ALLOWED_IPS"; then
  echo -e "${RED}✗ Invalid ALLOWED_IPS.${RESET}"
  exit 1
fi

[[ -z "${HOST+x}" ]] && HOST="$(existing_env HOST)"
HOST_RE='^[0-9A-Za-z.:%-]*$'
if [[ ! "$HOST" =~ $HOST_RE ]]; then
  echo -e "${RED}✗ HOST must be an IP address or hostname.${RESET}"
  exit 1
fi

if [[ "$KEY_SOURCE" == "generated" ]]; then
  echo -e "${GREEN}✓${RESET} API key generated. Enter it in the Home Assistant integration"
  echo "    (when adding it, or Settings → Devices & services → Apple Music → Reconfigure):"
  echo ""
  echo -e "      ${BOLD}${API_KEY}${RESET}"
  echo ""
  echo "    It is stored in $PLIST_DEST (readable only by you)."
elif [[ -n "$API_KEY" && "$KEY_SOURCE" == "existing" ]]; then
  echo -e "${GREEN}✓${RESET} Keeping existing API key (stored in $PLIST_DEST)"
elif [[ -n "$API_KEY" ]]; then
  echo -e "${GREEN}✓${RESET} Using API key from the API_KEY environment variable"
else
  echo -e "${YELLOW}⚠ No API key: any device that can reach port ${PORT} can control Music.${RESET}"
fi
if [[ -n "$ALLOWED_IPS" ]]; then
  echo -e "${GREEN}✓${RESET} Allowed IPs: $ALLOWED_IPS (localhost is always allowed)"
fi
case "$HOST" in
  ""|0.0.0.0|::|localhost|127.0.0.1|::1) ;;
  *) echo -e "${YELLOW}⚠ HOST=$HOST: notify.py posts to http://localhost:${PORT}, so instant updates need the server to listen on localhost too.${RESET}" ;;
esac

# ── 8. Unload any existing services ──────────────────────────────────────────
for label in "$PLIST_LABEL" "$NOTIFY_PLIST_LABEL"; do
  dest="$HOME/Library/LaunchAgents/${label}.plist"
  if launchctl list | grep -q "$label" 2>/dev/null; then
    launchctl unload "$dest" 2>/dev/null || true
  fi
done

# ── 9. Write API server plist ─────────────────────────────────────────────────
# The plist holds the API key, so create it private (umask) rather than chmod after
mkdir -p "$HOME/Library/LaunchAgents"
rm -f "$PLIST_DEST"
(
  umask 077
  sed \
    -e "s#%APP_PATH%#$APP_PATH#g" \
    -e "s#%PORT%#$PORT#g" \
    -e "s#%API_KEY%#$API_KEY#g" \
    -e "s#%ALLOWED_IPS%#$ALLOWED_IPS#g" \
    -e "s#%HOST%#$HOST#g" \
    -e "s#/usr/local/bin/node#$NODE_BIN#g" \
    "$APP_PATH/config/com.apple-music-api.plist" \
    > "$PLIST_DEST"
)
chmod 600 "$PLIST_DEST"
echo -e "${GREEN}✓${RESET} API server plist written"

# ── 10. Write notify plist ────────────────────────────────────────────────────
if [[ -n "$PYTHON_BIN" ]]; then
  cat > "$NOTIFY_PLIST_DEST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-music-notify</string>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_PATH}/bin/python3</string>
        <string>${APP_PATH}/notify.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${APP_PATH}/log/notify.log</string>
    <key>StandardErrorPath</key>
    <string>${APP_PATH}/log/notify.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>APPLE_MUSIC_API_URL</key>
        <string>http://localhost:${PORT}</string>
    </dict>
</dict>
</plist>
EOF
  echo -e "${GREEN}✓${RESET} Notification listener plist written"
fi

# ── 11. Load services ─────────────────────────────────────────────────────────
launchctl load -w "$PLIST_DEST"
echo -e "${GREEN}✓${RESET} API server loaded and set to start at login"

if [[ -n "$PYTHON_BIN" ]]; then
  launchctl load -w "$NOTIFY_PLIST_DEST"
  echo -e "${GREEN}✓${RESET} Notification listener loaded and set to start at login"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${RESET}"
echo ""
echo -e "  Server:       ${BOLD}http://localhost:${PORT}${RESET}"
echo -e "  Now playing:  http://localhost:${PORT}/now_playing"
echo -e "  Logs:         ${APP_PATH}/log/"
echo -e "  Listening on: ${HOST:-all interfaces}"
if [[ -n "$API_KEY" ]]; then
  echo -e "  API key:      required for clients other than this Mac"
else
  echo -e "  API key:      ${YELLOW}not required${RESET}"
fi
echo -e "  Allowed IPs:  ${ALLOWED_IPS:-any}"
echo ""
if [[ -z "$PYTHON_BIN" ]]; then
  echo -e "  ${YELLOW}⚠ Instant notifications not installed (Python 3.10+ required).${RESET}"
  echo -e "    Install Python and re-run: npm run install-service"
  echo ""
fi
echo "  To stop:      npm run uninstall-service"
echo "  To dev mode:  npm run dev"
echo ""
