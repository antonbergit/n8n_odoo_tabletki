#!/bin/bash

################################################################################
# n8n Backup Verification Script
# Purpose:  Verify integrity of existing backups
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================================================================"
echo "                   n8n BACKUP VERIFICATION"
echo "================================================================================"
echo ""

# Find all workflow backups
WORKFLOW_BACKUPS=$(ls -1 "${BACKUP_DIR}"/workflows_*.json 2>/dev/null || true)

if [ -z "$WORKFLOW_BACKUPS" ]; then
    echo -e "${RED}No backups found${NC}"
    exit 1
fi

echo "Found $(echo "$WORKFLOW_BACKUPS" | wc -l) backup(s)"
echo ""

# Verify each backup
while IFS= read -r workflow_file; do
    timestamp=$(basename "$workflow_file" | sed 's/workflows_\(.*\)\.json/\1/')
    db_file="${BACKUP_DIR}/database_${timestamp}.sql.gz"
    manifest_file="${BACKUP_DIR}/manifest_${timestamp}.txt"

    echo "Verifying backup: $timestamp"
    echo "----------------------------------------"

    # Check workflow file
    if [ -f "$workflow_file" ]; then
        size=$(du -h "$workflow_file" | cut -f1)
        if python3 -c "import json; json.load(open('$workflow_file'))" 2>/dev/null; then
            count=$(grep -o '"id":' "$workflow_file" | wc -l)
            echo -e "  Workflows: ${GREEN}✓${NC} ${size}, ${count} workflows"
        else
            echo -e "  Workflows: ${RED}✗${NC} Invalid JSON"
        fi
    else
        echo -e "  Workflows: ${RED}✗${NC} Missing"
    fi

    # Check database file
    if [ -f "$db_file" ]; then
        size=$(du -h "$db_file" | cut -f1)
        if gunzip -t "$db_file" 2>/dev/null; then
            echo -e "  Database:   ${GREEN}✓${NC} ${size}"
        else
            echo -e "  Database:   ${RED}✗${NC} Corrupted gzip"
        fi
    else
        echo -e "  Database:  ${RED}✗${NC} Missing"
    fi

    # Check manifest
    if [ -f "$manifest_file" ]; then
        echo -e "  Manifest:  ${GREEN}✓${NC}"
    else
        echo -e "  Manifest:  ${YELLOW}⚠${NC} Missing"
    fi

    echo ""
done <<< "$WORKFLOW_BACKUPS"

echo "================================================================================"
