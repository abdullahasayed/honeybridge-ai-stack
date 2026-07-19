#!/usr/bin/env bash
#
# restore-transfer.sh — integrate a transfer-bundle (from package-transfer.sh)
# onto THIS device: place .env / rag-files / docs-private, then load the n8n
# Postgres DB and Qdrant vectors into Docker volumes and bring the stack up.
#
# Usage:
#   ./scripts/restore-transfer.sh [--bundle DIR] [--profile NAME] [--force]
#
#   --bundle DIR    bundle location (default: ./transfer-bundle)
#   --profile NAME  compose profile for the final 'up' (default: cpu;
#                   Blue Runner / an NVIDIA host uses gpu-nvidia)
#   --force         skip the confirmation prompt before overwriting data
#
# DESTRUCTIVE: overwrites this machine's .env, n8n Postgres DB, and Qdrant
# volume. It prompts ONCE before that step unless --force is given.
# Requires Docker to be running.
#
set -uo pipefail

BUNDLE=""; PROFILE="cpu"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force|-y|--yes) FORCE=1 ;;
    --bundle=*)  BUNDLE="${1#*=}" ;;
    --bundle)    shift; BUNDLE="${1:-}" ;;
    --profile=*) PROFILE="${1#*=}" ;;
    --profile)   shift; PROFILE="${1:-}" ;;
    -h|--help)   grep '^#' "$0" | grep -v '^#!' | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

bold=$(tput bold 2>/dev/null || true);      blue=$(tput setaf 4 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true);    reset=$(tput sgr0 2>/dev/null || true)
log()  { printf '\n%s==>%s %s\n' "$bold$blue" "$reset" "$*"; }
ok()   { printf '%s[ok]%s   %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$yellow" "$reset" "$*"; }
die()  { printf '%s[err]%s  %s\n' "$red" "$reset" "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${BUNDLE:-$REPO/transfer-bundle}"

[ -d "$BUNDLE" ]                 || die "Bundle not found: $BUNDLE"
[ -f "$BUNDLE/.env" ]           || die "Bundle is missing .env — cannot restore (credentials would not decrypt)."
[ -f "$BUNDLE/volume-backups/n8n-postgres.sql" ] || die "Bundle is missing volume-backups/n8n-postgres.sql"
have docker && docker info >/dev/null 2>&1 || die "Docker isn't running. Open Docker Desktop, then re-run."

getenv() { local key="$1" def="${2:-}" val; val=$(grep -E "^${key}=" "$BUNDLE/.env" 2>/dev/null | head -1 | cut -d= -f2-); printf '%s' "${val:-$def}"; }
PGUSER="$(getenv POSTGRES_USER root)"
PGDB="$(getenv POSTGRES_DB n8n)"

log "Restoring HIVE from bundle: $BUNDLE"
[ -f "$BUNDLE/MANIFEST.txt" ] && sed 's/^/    /' "$BUNDLE/MANIFEST.txt"

# ---- confirmation ----------------------------------------------------------
if [ "$FORCE" -ne 1 ]; then
  warn "This OVERWRITES this machine's .env, the n8n Postgres database, and the Qdrant vector volume."
  printf '    Continue? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# ---- 1. file bits (non-Docker) --------------------------------------------
log "Placing .env and file bundles"
if [ -f "$REPO/.env" ] && ! cmp -s "$REPO/.env" "$BUNDLE/.env"; then
  cp "$REPO/.env" "$REPO/.env.bak.$(date +%s)"; warn "existing .env backed up to .env.bak.*"
fi
cp "$BUNDLE/.env" "$REPO/.env"; ok ".env"
if [ -d "$BUNDLE/shared/rag-files" ]; then mkdir -p "$REPO/shared"; cp -a "$BUNDLE/shared/rag-files" "$REPO/shared/"; ok "shared/rag-files"; fi
if [ -d "$BUNDLE/docs-private" ]; then mkdir -p "$REPO/docs-private"; cp -a "$BUNDLE/docs-private/." "$REPO/docs-private/"; ok "docs-private"; fi

# ---- 2. Docker volume restore ---------------------------------------------
log "Restoring the database and vectors (profile: $PROFILE)"
mkdir -p "$REPO/n8n/demo-data"; touch "$REPO/n8n/demo-data/.imported"   # skip auto-import so the DB isn't duplicated

( cd "$REPO" && docker compose --profile "$PROFILE" create ) || die "docker compose create failed"

VOL="$(docker volume ls --format '{{.Name}}' | grep -E '_qdrant_storage$' | head -1)"
[ -n "$VOL" ] || VOL="$(basename "$REPO" | tr '[:upper:]' '[:lower:]')_qdrant_storage"
if [ -f "$BUNDLE/volume-backups/qdrant_storage.tar.gz" ]; then
  docker run --rm -v "$VOL":/data -v "$BUNDLE/volume-backups":/backup alpine \
    sh -c "cd /data && tar xzf /backup/qdrant_storage.tar.gz" \
    && ok "Qdrant vectors → volume '$VOL'" || die "Qdrant restore failed"
else
  warn "no qdrant_storage.tar.gz in bundle — skipping vector restore"
fi

( cd "$REPO" && docker compose up -d postgres ) || die "failed to start postgres"
printf '    waiting for postgres'; for _ in 1 2 3 4 5 6 7 8 9 10; do printf '.'; sleep 1; done; echo
( cd "$REPO" && docker compose exec -T postgres psql -U "$PGUSER" -d "$PGDB" ) < "$BUNDLE/volume-backups/n8n-postgres.sql" \
    && ok "n8n database imported" || die "psql import failed"

# ---- 3. bring everything up ------------------------------------------------
( cd "$REPO" && docker compose --profile "$PROFILE" up -d ) || die "docker compose up failed"

log "Done — HIVE restored on this device."
echo  "  n8n:        http://localhost:5678   (workflows + credentials came across; encryption key preserved)"
echo  "  chat UI:    http://localhost:8080"
echo  "  Qdrant:     http://localhost:6333/dashboard"
warn  "If this host is reached remotely, review docs-private/HIVE-access-and-onboarding.md (Tailscale + webhook URL)."
