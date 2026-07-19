#!/usr/bin/env bash
#
# package-transfer.sh — bundle the machine-local, gitignored state that HIVE
# needs to move to another device into ./transfer-bundle, regenerating FRESH
# database + vector backups from the running stack.
#
# What goes in the bundle (all gitignored — never in the repo):
#   .env                fresh copy — the n8n encryption key + secrets (REQUIRED)
#   volume-backups/     fresh pg_dump + Qdrant volume tar (regenerated on run)
#   shared/rag-files/   source documents (pending + processed)
#   docs-private/       private planning docs + the onboarding doc
#
# Usage:
#   ./scripts/package-transfer.sh [--out DIR] [--cold] [--no-refresh]
#
#   --out DIR      write the bundle to DIR (default: ./transfer-bundle)
#   --cold         stop the stack for a consistent Qdrant snapshot, then restart
#                  (default: hot snapshot — no downtime, fine for migration)
#   --no-refresh   don't regenerate backups; copy the existing volume-backups/
#                  snapshot as-is (use when Docker isn't running — may be stale)
#
# SECURITY: the bundle contains secrets (the n8n encryption key, the DB
# password, and the Postgres dump of encrypted credentials). Move it
# out-of-band (Tailscale taildrop / encrypted drive). Never commit or email it.
# transfer-bundle/ is gitignored.
#
set -uo pipefail

# ---- args ------------------------------------------------------------------
OUT=""; COLD=0; REFRESH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --cold)       COLD=1 ;;
    --no-refresh) REFRESH=0 ;;
    --out=*)      OUT="${1#*=}" ;;
    --out)        shift; OUT="${1:-}" ;;
    -h|--help)    grep '^#' "$0" | grep -v '^#!' | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

# ---- pretty output ---------------------------------------------------------
bold=$(tput bold 2>/dev/null || true);      blue=$(tput setaf 4 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true);    reset=$(tput sgr0 2>/dev/null || true)
log()  { printf '\n%s==>%s %s\n' "$bold$blue" "$reset" "$*"; }
ok()   { printf '%s[ok]%s   %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$yellow" "$reset" "$*"; }
die()  { printf '%s[err]%s  %s\n' "$red" "$reset" "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- paths -----------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${OUT:-$REPO/transfer-bundle}"
[ -f "$REPO/.env" ] || die ".env not found in $REPO — nothing to package. HIVE can't be reproduced without it."

getenv() { # <KEY> [default]
  local key="$1" def="${2:-}" val
  val=$(grep -E "^${key}=" "$REPO/.env" 2>/dev/null | head -1 | cut -d= -f2-)
  printf '%s' "${val:-$def}"
}
PGUSER="$(getenv POSTGRES_USER root)"
PGDB="$(getenv POSTGRES_DB n8n)"

docker_up() { have docker && docker info >/dev/null 2>&1; }
pg_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx postgres; }
qdrant_volume() {
  local v
  v=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_qdrant_storage$' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  printf '%s_qdrant_storage' "$(basename "$REPO" | tr '[:upper:]' '[:lower:]')"
}

# ---- build a clean bundle --------------------------------------------------
log "Packaging HIVE transfer bundle → $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/volume-backups"

# .env (required)
cp "$REPO/.env" "$BUNDLE/.env"
ok ".env"

# volume-backups — regenerate fresh from the running stack, or copy as-is
if [ "$REFRESH" -eq 1 ] && docker_up && pg_running; then
  log "Regenerating fresh backups from the running stack"

  ( cd "$REPO" && docker compose exec -T postgres \
      pg_dump -U "$PGUSER" -d "$PGDB" --clean --if-exists --no-owner ) \
      > "$BUNDLE/volume-backups/n8n-postgres.sql" \
      && ok "n8n-postgres.sql ($(du -h "$BUNDLE/volume-backups/n8n-postgres.sql" | cut -f1))" \
      || die "pg_dump failed"

  VOL="$(qdrant_volume)"
  if [ "$COLD" -eq 1 ]; then
    warn "Cold snapshot: stopping the stack for a consistent Qdrant export"
    ( cd "$REPO" && docker compose stop )
  fi
  docker run --rm -v "$VOL":/data:ro -v "$BUNDLE/volume-backups":/backup alpine \
      sh -c "cd /data && tar czf /backup/qdrant_storage.tar.gz ." \
      && ok "qdrant_storage.tar.gz ($(du -h "$BUNDLE/volume-backups/qdrant_storage.tar.gz" | cut -f1)) from volume '$VOL'" \
      || die "Qdrant volume export failed (volume '$VOL')"
  if [ "$COLD" -eq 1 ]; then
    ( cd "$REPO" && docker compose start )
    ok "stack restarted"
  fi
else
  if [ "$REFRESH" -eq 1 ]; then
    warn "Docker/postgres not running — falling back to the existing volume-backups/ snapshot (may be STALE)."
  fi
  if [ -d "$REPO/volume-backups" ] && ls "$REPO"/volume-backups/* >/dev/null 2>&1; then
    cp -a "$REPO"/volume-backups/. "$BUNDLE/volume-backups/"
    ok "copied existing volume-backups/ (not regenerated)"
  else
    die "No running stack AND no existing volume-backups/ — cannot capture the DB/vectors. Start the stack and re-run."
  fi
fi

# shared/rag-files — source documents
if [ -d "$REPO/shared/rag-files" ]; then
  mkdir -p "$BUNDLE/shared"
  cp -a "$REPO/shared/rag-files" "$BUNDLE/shared/"
  ok "shared/rag-files ($(du -sh "$BUNDLE/shared/rag-files" | cut -f1))"
fi

# docs-private — planning + onboarding docs
if [ -d "$REPO/docs-private" ]; then
  cp -a "$REPO/docs-private" "$BUNDLE/docs-private"
  ok "docs-private"
fi

# ---- manifest --------------------------------------------------------------
GIT_SHA=$( ( cd "$REPO" && git rev-parse --short HEAD 2>/dev/null ) || echo "unknown")
{
  echo "HIVE transfer bundle"
  echo "packaged:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "from host: $(hostname)"
  echo "git:       $GIT_SHA"
  echo "refresh:   $([ "$REFRESH" -eq 1 ] && echo 'fresh regen' || echo 'copied existing') / $([ "$COLD" -eq 1 ] && echo cold || echo hot) snapshot"
  echo
  echo "Contents (all gitignored):"
  echo "  .env                     n8n encryption key + secrets — REQUIRED for credential decryption"
  echo "  volume-backups/          Postgres dump (workflows/creds/history) + Qdrant vectors (hivebrain)"
  echo "  shared/rag-files/        source documents"
  echo "  docs-private/            planning + onboarding docs"
  echo
  echo "Restore on the new device:  ./scripts/restore-transfer.sh --bundle <this folder>"
  echo "SECURITY: contains secrets — move out-of-band, never commit."
} > "$BUNDLE/MANIFEST.txt"

log "Done."
printf '  Bundle:  %s  (%s total)\n' "$BUNDLE" "$(du -sh "$BUNDLE" | cut -f1)"
warn "Contains secrets — move it out-of-band (Tailscale taildrop / encrypted drive). Never commit or email it."
echo  "  Next: copy transfer-bundle/ to the new device's repo root, then run ./scripts/setup.sh (or ./scripts/restore-transfer.sh)."
