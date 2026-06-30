#Requires -Version 5
<#
.SYNOPSIS
  Install everything needed to run HIVE, plus optional dev tools. (Windows)

.DESCRIPTION
  Uses winget (ships with Windows 11 and recent Windows 10). Idempotent --
  skips anything that's already installed. Run in an elevated PowerShell so
  Docker Desktop installs cleanly.

.PARAMETER WithDevTools
  Also install Node.js, Claude Code, ChatGPT, and Codex.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -WithDevTools
#>
param(
  [switch]$WithDevTools
)

$ErrorActionPreference = 'Continue'

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ok]   $m" -ForegroundColor Green }
function Write-Skip($m) { Write-Host "[skip] $m" -ForegroundColor Yellow }

# ---- winget present? -------------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Red
  exit 1
}

# ---- admin hint ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Tip: run this in an elevated PowerShell (Run as Administrator) so Docker Desktop installs cleanly." -ForegroundColor Yellow
}

# ---- helper ----------------------------------------------------------------
function Ensure-Package {
  param([string]$Id, [string]$Name = $Id)
  $found = winget list --id $Id -e --accept-source-agreements 2>$null | Select-String -SimpleMatch $Id
  if ($found) { Write-Skip $Name; return }
  Write-Step "Installing $Name"
  winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements --silent
  if ($LASTEXITCODE -eq 0) { Write-Ok $Name } else { Write-Skip "$Name (winget id may have changed)" }
}

# ---- core dependencies -----------------------------------------------------
Write-Step "Core dependencies"
Ensure-Package 'Git.Git'              'Git'
Ensure-Package 'GitHub.cli'           'GitHub CLI'
Ensure-Package 'GitHub.GitHubDesktop' 'GitHub Desktop'
Ensure-Package 'jqlang.jq'            'jq'
Ensure-Package 'Docker.DockerDesktop' 'Docker Desktop'
Ensure-Package 'Ollama.Ollama'        'Ollama'   # optional for the Docker setup (see notes)

# ---- optional developer tools ----------------------------------------------
if ($WithDevTools) {
  Write-Step "Optional developer tools"
  Ensure-Package 'OpenJS.NodeJS' 'Node.js'
  Ensure-Package 'OpenAI.ChatGPT' 'ChatGPT'
  # Prefer the Claude desktop app instead of the CLI? Uncomment:
  # Ensure-Package 'Anthropic.Claude' 'Claude (desktop)'

  # Refresh PATH so a freshly-installed npm is visible in this session
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

  if (Get-Command npm -ErrorAction SilentlyContinue) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      Write-Skip 'claude (Claude Code)'
    } else {
      Write-Step 'Installing Claude Code'
      npm install -g @anthropic-ai/claude-code
      if ($LASTEXITCODE -eq 0) { Write-Ok 'claude' } else { Write-Skip 'claude' }
    }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      Write-Skip 'codex'
    } else {
      Write-Step 'Installing Codex CLI'
      npm install -g @openai/codex
      if ($LASTEXITCODE -eq 0) { Write-Ok 'codex' } else { Write-Skip 'codex' }
    }
  } else {
    Write-Skip 'npm not found (restart the terminal after Node installs, then re-run) -- skipping Claude Code and Codex'
  }
}

# ---- Ollama models for HIVE ------------------------------------------------
# HIVE talks to the Ollama running INSIDE Docker, so the models must live there.
# The stack pulls them automatically on first 'docker compose up'. If the Docker
# container is already running, pull them now too.
Write-Step "Ollama models for HIVE"
$hiveModels = @('nomic-embed-text','gemma4:e4b')
$ollamaUp = (Get-Command docker -ErrorAction SilentlyContinue) -and ((docker ps --format '{{.Names}}' 2>$null) -contains 'ollama')
if ($ollamaUp) {
  foreach ($m in $hiveModels) {
    docker exec ollama ollama pull $m
    if ($LASTEXITCODE -eq 0) { Write-Ok "model: $m" } else { Write-Skip "model: $m (pull failed -- verify the tag exists)" }
  }
} else {
  Write-Skip "models pull automatically on first 'docker compose --profile cpu up'"
}

# ---- next steps ------------------------------------------------------------
Write-Step "Done. Next steps:"
@"
  1. Restart your terminal so PATH updates (git, gh, docker, npm).
  2. Open Docker Desktop once and accept the license. It needs WSL2 -- accept its
     first-run prompt, or run 'wsl --install' in an admin terminal and reboot.
  3. Clone into a folder named 'honeybridge-ai-stack', then follow the README "Quick start".
     (The bash-style docker/restore commands run in Git Bash or WSL.)
  4. The stack runs Ollama inside Docker, so native Ollama is optional. If you run it on
     the host, see the README note to avoid a port 11434 clash.
"@ | Write-Host
