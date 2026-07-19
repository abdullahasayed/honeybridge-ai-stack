#Requires -Version 5
<#
.SYNOPSIS
  Integrate a transfer-bundle (from package-transfer) onto THIS device: place
  .env / rag-files / docs-private, then load the n8n DB and Qdrant vectors into
  Docker volumes and bring the stack up. (Windows)

.DESCRIPTION
  DESTRUCTIVE: overwrites this machine's .env, the n8n Postgres DB, and the
  Qdrant volume. Prompts ONCE before that step unless -Force. Requires Docker
  to be running.

.PARAMETER Bundle
  Bundle location (default: .\transfer-bundle).
.PARAMETER Profile
  Compose profile for the final 'up' (default: cpu; an NVIDIA host uses gpu-nvidia).
.PARAMETER Force
  Skip the confirmation prompt.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\restore-transfer.ps1 -Profile gpu-nvidia
#>
param(
  [string]$Bundle,
  [string]$Profile = 'cpu',
  [switch]$Force
)
$ErrorActionPreference = 'Continue'

function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "[ok]   $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die($m)       { Write-Host "[err]  $m" -ForegroundColor Red; exit 1 }

$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Bundle) { $Bundle = Join-Path $Repo 'transfer-bundle' }

if (-not (Test-Path $Bundle)) { Die "Bundle not found: $Bundle" }
if (-not (Test-Path (Join-Path $Bundle '.env'))) { Die "Bundle missing .env — cannot restore (credentials would not decrypt)." }
$sqlPath = Join-Path $Bundle 'volume-backups\n8n-postgres.sql'
if (-not (Test-Path $sqlPath)) { Die "Bundle missing volume-backups\n8n-postgres.sql" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Die "docker not found." }
docker info *> $null; if ($LASTEXITCODE -ne 0) { Die "Docker isn't running. Open Docker Desktop, then re-run." }

function Get-EnvVal($key,$def){
  $l = Select-String -Path (Join-Path $Bundle '.env') -Pattern "^$key=" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($l) { return ($l.Line -replace "^$key=","") } else { return $def }
}
$PGUSER = Get-EnvVal 'POSTGRES_USER' 'root'
$PGDB   = Get-EnvVal 'POSTGRES_DB'   'n8n'

Write-Step "Restoring HIVE from bundle: $Bundle"
if (Test-Path (Join-Path $Bundle 'MANIFEST.txt')) { Get-Content (Join-Path $Bundle 'MANIFEST.txt') | ForEach-Object { "    $_" } | Write-Host }

if (-not $Force) {
  Write-Warn "This OVERWRITES this machine's .env, the n8n Postgres database, and the Qdrant vector volume."
  $reply = Read-Host "    Continue? [y/N]"
  if ($reply -notmatch '^(y|Y|yes|YES)$') { Write-Host "Aborted."; exit 0 }
}

# ---- 1. file bits ----------------------------------------------------------
Write-Step "Placing .env and file bundles"
$repoEnv = Join-Path $Repo '.env'
if ((Test-Path $repoEnv) -and ((Get-FileHash $repoEnv).Hash -ne (Get-FileHash (Join-Path $Bundle '.env')).Hash)) {
  Copy-Item $repoEnv "$repoEnv.bak.$([int](Get-Date -UFormat %s))"; Write-Warn "existing .env backed up to .env.bak.*"
}
Copy-Item (Join-Path $Bundle '.env') $repoEnv -Force; Write-Ok ".env"
if (Test-Path (Join-Path $Bundle 'shared\rag-files')) {
  $dst = Join-Path $Repo 'shared\rag-files'; New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $Bundle 'shared\rag-files\*') $dst -Recurse -Force; Write-Ok "shared\rag-files"
}
if (Test-Path (Join-Path $Bundle 'docs-private')) {
  $dst = Join-Path $Repo 'docs-private'; New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $Bundle 'docs-private\*') $dst -Recurse -Force; Write-Ok "docs-private"
}

# ---- 2. Docker volume restore ---------------------------------------------
Write-Step "Restoring the database and vectors (profile: $Profile)"
New-Item -ItemType Directory -Force -Path (Join-Path $Repo 'n8n\demo-data') | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $Repo 'n8n\demo-data\.imported') | Out-Null  # skip auto-import

Push-Location $Repo
docker compose --profile $Profile create
if ($LASTEXITCODE -ne 0) { Pop-Location; Die "docker compose create failed" }

$vol = docker volume ls --format '{{.Name}}' | Select-String -Pattern '_qdrant_storage$' | Select-Object -First 1
if ($vol) { $vol = $vol.ToString().Trim() } else { $vol = ((Split-Path $Repo -Leaf).ToLower() + '_qdrant_storage') }
$tgz = Join-Path $Bundle 'volume-backups\qdrant_storage.tar.gz'
if (Test-Path $tgz) {
  docker run --rm -v "${vol}:/data" -v "$((Join-Path $Bundle 'volume-backups')):/backup" alpine sh -c "cd /data && tar xzf /backup/qdrant_storage.tar.gz"
  if ($LASTEXITCODE -eq 0) { Write-Ok "Qdrant vectors -> volume '$vol'" } else { Pop-Location; Die "Qdrant restore failed" }
} else { Write-Warn "no qdrant_storage.tar.gz in bundle — skipping vector restore" }

docker compose up -d postgres
if ($LASTEXITCODE -ne 0) { Pop-Location; Die "failed to start postgres" }
Write-Host "    waiting for postgres..."; Start-Sleep -Seconds 10
# cmd /c '<' feeds the raw dump bytes into psql (PowerShell piping would re-encode)
cmd /c "docker compose exec -T postgres psql -U $PGUSER -d $PGDB < `"$sqlPath`""
if ($LASTEXITCODE -eq 0) { Write-Ok "n8n database imported" } else { Pop-Location; Die "psql import failed" }

docker compose --profile $Profile up -d
Pop-Location
if ($LASTEXITCODE -ne 0) { Die "docker compose up failed" }

Write-Step "Done — HIVE restored on this device."
Write-Host "  n8n:     http://localhost:5678   (workflows + credentials came across; encryption key preserved)"
Write-Host "  chat UI: http://localhost:8080"
Write-Host "  Qdrant:  http://localhost:6333/dashboard"
Write-Warn "If this host is reached remotely, review docs-private\HIVE-access-and-onboarding.md (Tailscale + webhook URL)."
