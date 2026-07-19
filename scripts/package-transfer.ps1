#Requires -Version 5
<#
.SYNOPSIS
  Bundle the machine-local, gitignored state HIVE needs to move to another
  device into .\transfer-bundle, regenerating FRESH DB + vector backups. (Windows)

.DESCRIPTION
  Gathers every gitignored file needed to reproduce HIVE:
    .env               n8n encryption key + secrets (REQUIRED)
    volume-backups\    fresh pg_dump + Qdrant volume tar (regenerated on run)
    shared\rag-files\  source documents
    docs-private\      planning + onboarding docs

  SECURITY: the bundle contains secrets (encryption key, DB password, and the
  Postgres dump of encrypted credentials). Move it out-of-band (Tailscale
  taildrop / encrypted drive). Never commit or email it. transfer-bundle\ is
  gitignored.

.PARAMETER Out
  Destination folder (default: .\transfer-bundle).
.PARAMETER Cold
  Stop the stack for a consistent Qdrant snapshot, then restart (default: hot).
.PARAMETER NoRefresh
  Don't regenerate backups; copy the existing volume-backups\ as-is (may be stale).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\package-transfer.ps1
#>
param(
  [string]$Out,
  [switch]$Cold,
  [switch]$NoRefresh
)
$ErrorActionPreference = 'Continue'

function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "[ok]   $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die($m)       { Write-Host "[err]  $m" -ForegroundColor Red; exit 1 }

$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envPath = Join-Path $Repo '.env'
if (-not (Test-Path $envPath)) { Die ".env not found in $Repo — HIVE can't be reproduced without it." }
$Bundle = if ($Out) { $Out } else { Join-Path $Repo 'transfer-bundle' }

function Get-EnvVal($key,$def){
  $l = Select-String -Path $envPath -Pattern "^$key=" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($l) { return ($l.Line -replace "^$key=","") } else { return $def }
}
$PGUSER = Get-EnvVal 'POSTGRES_USER' 'root'
$PGDB   = Get-EnvVal 'POSTGRES_DB'   'n8n'

function Test-DockerUp { if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }; docker info *> $null; return ($LASTEXITCODE -eq 0) }
function Test-PgRunning { (docker ps --format '{{.Names}}' 2>$null) -contains 'postgres' }
function Get-QdrantVolume {
  $v = docker volume ls --format '{{.Name}}' 2>$null | Select-String -Pattern '_qdrant_storage$' | Select-Object -First 1
  if ($v) { return $v.ToString().Trim() } else { return ((Split-Path $Repo -Leaf).ToLower() + '_qdrant_storage') }
}

Write-Step "Packaging HIVE transfer bundle -> $Bundle"
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
New-Item -ItemType Directory -Force -Path (Join-Path $Bundle 'volume-backups') | Out-Null

Copy-Item $envPath (Join-Path $Bundle '.env') -Force
Write-Ok ".env"

$sqlPath = Join-Path $Bundle 'volume-backups\n8n-postgres.sql'
$tgzPath = Join-Path $Bundle 'volume-backups\qdrant_storage.tar.gz'

if (-not $NoRefresh -and (Test-DockerUp) -and (Test-PgRunning)) {
  Write-Step "Regenerating fresh backups from the running stack"
  Push-Location $Repo
  # cmd /c keeps the raw byte stream intact (PowerShell '>' would re-encode to UTF-16 and corrupt the dump)
  cmd /c "docker compose exec -T postgres pg_dump -U $PGUSER -d $PGDB --clean --if-exists --no-owner > `"$sqlPath`""
  Pop-Location
  if (-not (Test-Path $sqlPath) -or (Get-Item $sqlPath).Length -eq 0) { Die "pg_dump failed" }
  Write-Ok ("n8n-postgres.sql ({0:N0} KB)" -f ((Get-Item $sqlPath).Length/1KB))

  $vol = Get-QdrantVolume
  if ($Cold) { Write-Warn "Cold snapshot: stopping the stack"; Push-Location $Repo; docker compose stop; Pop-Location }
  docker run --rm -v "${vol}:/data:ro" -v "$((Join-Path $Bundle 'volume-backups')):/backup" alpine sh -c "cd /data && tar czf /backup/qdrant_storage.tar.gz ."
  if (-not (Test-Path $tgzPath)) { Die "Qdrant volume export failed (volume '$vol')" }
  Write-Ok ("qdrant_storage.tar.gz ({0:N0} KB) from volume '$vol'" -f ((Get-Item $tgzPath).Length/1KB))
  if ($Cold) { Push-Location $Repo; docker compose start; Pop-Location; Write-Ok "stack restarted" }
}
else {
  if (-not $NoRefresh) { Write-Warn "Docker/postgres not running — falling back to existing volume-backups\ (may be STALE)." }
  $src = Join-Path $Repo 'volume-backups'
  if ((Test-Path $src) -and (Get-ChildItem $src -File -ErrorAction SilentlyContinue)) {
    Copy-Item (Join-Path $src '*') (Join-Path $Bundle 'volume-backups') -Recurse -Force
    Write-Ok "copied existing volume-backups\ (not regenerated)"
  } else {
    Die "No running stack AND no existing volume-backups\ — start the stack and re-run."
  }
}

# shared\rag-files
$rag = Join-Path $Repo 'shared\rag-files'
if (Test-Path $rag) { New-Item -ItemType Directory -Force -Path (Join-Path $Bundle 'shared') | Out-Null; Copy-Item $rag (Join-Path $Bundle 'shared\rag-files') -Recurse -Force; Write-Ok "shared\rag-files" }

# docs-private
$dp = Join-Path $Repo 'docs-private'
if (Test-Path $dp) { Copy-Item $dp (Join-Path $Bundle 'docs-private') -Recurse -Force; Write-Ok "docs-private" }

# manifest
$gitSha = (& git -C $Repo rev-parse --short HEAD 2>$null); if (-not $gitSha) { $gitSha = 'unknown' }
$snap = if ($NoRefresh) { 'copied existing' } else { 'fresh regen' }; $temp = if ($Cold) { 'cold' } else { 'hot' }
@"
HIVE transfer bundle
packaged:  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
from host: $env:COMPUTERNAME
git:       $gitSha
refresh:   $snap / $temp snapshot

Contents (all gitignored):
  .env                     n8n encryption key + secrets — REQUIRED for credential decryption
  volume-backups/          Postgres dump (workflows/creds/history) + Qdrant vectors (hivebrain)
  shared/rag-files/        source documents
  docs-private/            planning + onboarding docs

Restore on the new device:  ./scripts/restore-transfer.sh  (or .ps1)  --bundle <this folder>
SECURITY: contains secrets — move out-of-band, never commit.
"@ | Set-Content -Path (Join-Path $Bundle 'MANIFEST.txt') -Encoding UTF8

Write-Step "Done."
Write-Host "  Bundle: $Bundle"
Write-Warn "Contains secrets — move out-of-band (Tailscale taildrop / encrypted drive). Never commit or email it."
Write-Host "  Next: copy transfer-bundle\ to the new device's repo root, then run setup (or restore-transfer)."
