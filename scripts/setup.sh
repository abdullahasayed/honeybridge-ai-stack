#!/usr/bin/env bash
#
# setup.sh — install everything needed to run HIVE, plus optional dev tools.
#
# Target: macOS (Apple Silicon or Intel). On Linux, install the equivalents
# with your package manager: docker, docker compose, git, gh, ollama.
#
# Usage:
#   ./scripts/setup.sh                    # core dependencies only
#   ./scripts/setup.sh --with-dev-tools   # also install Claude Code, ChatGPT, Codex
#
# The script is idempotent — it skips anything that's already installed.
#
set -uo pipefail

WITH_DEV_TOOLS=0
for arg in "$@"; do
  case "$arg" in
    --with-dev-tools|--dev) WITH_DEV_TOOLS=1 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

# ---- pretty output ---------------------------------------------------------
bold=$(tput bold 2>/dev/null || true);    blue=$(tput setaf 4 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)
log()  { printf '\n%s==>%s %s\n' "$bold$blue" "$reset" "$*"; }
ok()   { printf '%s[ok]%s   %s\n' "$green" "$reset" "$*"; }
skip() { printf '%s[skip]%s %s\n' "$yellow" "$reset" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- platform guard --------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script targets macOS. On Linux, install: docker, docker compose, git, gh, ollama."
  exit 1
fi

# ---- Xcode Command Line Tools ----------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (a dialog will appear)"
  xcode-select --install || true
  echo "Finish the Command Line Tools install, then re-run ./scripts/setup.sh"
  exit 0
fi
ok "Xcode Command Line Tools"

# ---- Homebrew --------------------------------------------------------------
if ! have brew; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Put brew on PATH for this session (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if   [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ];   then eval "$(/usr/local/bin/brew shellenv)"; fi
have brew || { echo "Homebrew install failed — see https://brew.sh"; exit 1; }
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ---- helpers ---------------------------------------------------------------
formula() {  # <formula> [check-command]
  local f="$1" cmd="${2:-$1}"
  if have "$cmd"; then skip "$f"; return; fi
  log "Installing $f"; brew install "$f" && ok "$f" || skip "$f (install failed)"
}
cask() {  # <cask> "</Applications/App.app>"
  local c="$1" app="$2"
  if [ -d "$app" ] || brew list --cask "$c" >/dev/null 2>&1; then skip "$c"; return; fi
  log "Installing $c"; brew install --cask "$c" && ok "$c" || skip "$c (cask name may have changed)"
}

# ---- core dependencies -----------------------------------------------------
log "Core dependencies"
formula git
formula gh
formula jq
cask github "/Applications/GitHub Desktop.app"

# Docker Desktop (bundles the engine + docker compose); cask was renamed, so try both
if [ -d "/Applications/Docker.app" ] || have docker; then
  skip "Docker Desktop"
else
  log "Installing Docker Desktop"
  if brew install --cask docker-desktop || brew install --cask docker; then
    ok "Docker Desktop"
  else
    skip "Docker Desktop — install manually from https://www.docker.com/products/docker-desktop/"
  fi
fi

# Native Ollama (optional for the Docker setup — see the note at the end)
formula ollama ollama

# ---- optional developer tools ----------------------------------------------
if [ "$WITH_DEV_TOOLS" -eq 1 ]; then
  log "Optional developer tools"
  formula node node   # provides npm for the CLIs below

  if have npm; then
    if have claude; then skip "claude (Claude Code)"; else
      log "Installing Claude Code"; npm install -g @anthropic-ai/claude-code && ok "claude" || skip "claude"
    fi
    if have codex; then skip "codex"; else
      log "Installing Codex CLI"; npm install -g @openai/codex && ok "codex" || skip "codex"
    fi
  else
    skip "npm not found — skipping Claude Code and Codex"
  fi

  cask chatgpt "/Applications/ChatGPT.app"
  # Prefer the Claude desktop app instead of the CLI? Uncomment:
  # cask claude "/Applications/Claude.app"
fi

# ---- Ollama models for HIVE ------------------------------------------------
# HIVE talks to the Ollama running INSIDE Docker, so the models must live there.
# The stack pulls them automatically on first `docker compose up` (the ollama
# init service). If the Docker container is already running, pull them now too.
log "Ollama models for HIVE"
HIVE_MODELS="nomic-embed-text gemma4:e4b"
if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ollama; then
  for m in $HIVE_MODELS; do
    docker exec ollama ollama pull "$m" && ok "model: $m" || skip "model: $m (pull failed — verify the tag exists)"
  done
else
  skip "models pull automatically on first 'docker compose --profile cpu up'"
fi

# ---- next steps ------------------------------------------------------------
log "Done. Next steps:"
cat <<'EOF'
  1. Open Docker Desktop once and accept the license (the `docker` CLI needs it running).
  2. Clone into a folder named 'honeybridge-ai-stack', then follow the README "Quick start".
  3. The stack runs Ollama inside Docker, so native Ollama is optional. If you DO run it on
     the host, see the README note "For Mac users running Ollama locally" to avoid a port
     11434 clash.
EOF
