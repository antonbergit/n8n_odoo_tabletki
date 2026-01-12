#!/bin/bash

################################################################################
# n8n Restore Script
# Purpose: Restore workflows and database from backup
# Usage: ./restore_n8n. sh <backup_timestamp>
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
N8N_CONTAINER="n8n-n8n-1"
POSTGRES_CONTAINER="n8n-postgres-1"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <backup_timestamp>"
    echo ""
    echo "Available backups:"
    ls -1 "${BACKUP_DIR}"/workflows_*.json 2>/dev/null | sed 's/.*workflows_\(.*\)\.json/  \1/' || echo "  No backups found"
    exit 1
fi

TIMESTAMP=$1
WORKFLOW_FILE="${BACKUP_DIR}/workflows_${TIMESTAMP}.json"
DB_FILE="${BACKUP_DIR}/database_${TIMESTAMP}.sql. gz"

# Verify backup files exist
[ -f "$WORKFLOW_FILE" ] || error_exit "Workflow backup not found: $WORKFLOW_FILE"
[ -f "$DB_FILE" ] || error_exit "Database backup not found: $DB_FILE"

echo "================================================================================"
echo "                          n8n RESTORE SCRIPT"
echo "================================================================================"
echo ""
echo "This will restore:"
echo "  - Workflows from: $(basename "$WORKFLOW_FILE")"
echo "  - Database from:   $(basename "$DB_FILE")"
echo ""
warning "THIS WILL OVERWRITE CURRENT DATA!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo ""

if [[ !  $REPLY =~ ^yes$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# Restore workflows
echo "Restoring workflows..."
if docker cp "$WORKFLOW_FILE" "${N8N_CONTAINER}:/tmp/workflows_restore.json"; then
    docker exec "$N8N_CONTAINER" n8n import:workflow --input=/tmp/workflows_restore.json --separate
    success "Workflows restored"
else
    error_exit "Failed to restore workflows"
fi

# Restore database
echo "Restoring database..."
if gunzip -c "$DB_FILE" | docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" "$POSTGRES_DB"; then
    success "Database restored"
else
    error_exit "Failed to restore database"
fi

success "Restore completed successfully!"
echo ""
echo "Please restart n8n container:"
echo "  docker restart ${N8N_CONTAINER}"
