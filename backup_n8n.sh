#!/bin/bash

################################################################################
# n8n Backup Script with Diagnostics
# Purpose: Backup workflows and PostgreSQL database with validation
# Usage: ./backup_n8n. sh [options]
# Options:
#   -v, --verbose    Verbose output
#   -t, --test       Test mode (no actual backup)
#   -k, --keep N     Keep last N backups (default: 7)
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ============================================================================
# CONFIGURATION
# ============================================================================

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
LOG_DIR="${SCRIPT_DIR}/logs"
TEMP_DIR="/tmp/n8n_backup_$$"

# Create LOG_DIR early (before any logging)
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Container names (auto-detect or set manually)
N8N_CONTAINER="n8n-n8n-1"
POSTGRES_CONTAINER="n8n-postgres-1"

# PostgreSQL credentials (adjust if different)
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"

# Retention policy
KEEP_BACKUPS=7  # Keep last 7 backups by default

# Logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/backup_${TIMESTAMP}.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Flags
VERBOSE=false
TEST_MODE=false

# ============================================================================
# FUNCTIONS
# ============================================================================

# Logging function
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"

    case $level in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} ${message}"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} ${message}"
            ;;
        INFO)
            if [ "$VERBOSE" = true ]; then
                echo -e "${BLUE}[INFO]${NC} ${message}"
            fi
            ;;
    esac
}

# Error handler
error_exit() {
    log ERROR "$1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log INFO "Cleaning up temporary directory:  $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Trap errors and interrupts
trap cleanup EXIT
trap 'error_exit "Script interrupted"' INT TERM

# Create necessary directories
setup_directories() {
    log INFO "Setting up directories..."

    mkdir -p "$BACKUP_DIR" || error_exit "Failed to create backup directory:  $BACKUP_DIR"
    mkdir -p "$LOG_DIR" || error_exit "Failed to create log directory: $LOG_DIR"
    mkdir -p "$TEMP_DIR" || error_exit "Failed to create temp directory: $TEMP_DIR"

    log SUCCESS "Directories created successfully"
}

# Check if Docker is running
check_docker() {
    log INFO "Checking Docker status..."

    if ! command -v docker &> /dev/null; then
        error_exit "Docker command not found. Is Docker installed?"
    fi

    if ! docker ps &> /dev/null; then
        error_exit "Cannot connect to Docker daemon. Is Docker running?"
    fi

    log SUCCESS "Docker is running"
}

# Check if containers are running
check_containers() {
    log INFO "Checking container status..."

    # Check n8n container
    if ! docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
        error_exit "n8n container '${N8N_CONTAINER}' is not running"
    fi
    log SUCCESS "n8n container is running"

    # Check PostgreSQL container
    if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
        error_exit "PostgreSQL container '${POSTGRES_CONTAINER}' is not running"
    fi
    log SUCCESS "PostgreSQL container is running"

    # Get container uptime
    local n8n_uptime=$(docker ps --filter "name=${N8N_CONTAINER}" --format '{{.Status}}')
    local pg_uptime=$(docker ps --filter "name=${POSTGRES_CONTAINER}" --format '{{.Status}}')

    log INFO "n8n uptime: ${n8n_uptime}"
    log INFO "PostgreSQL uptime: ${pg_uptime}"
}

# Check disk space
check_disk_space() {
    log INFO "Checking disk space..."

    # Check available space on backup directory
    local available=$(df -BM "$BACKUP_DIR" | awk 'NR==2 {print $4}' | sed 's/M//')
    local required=50  # Minimum 50MB required

    if [ "$available" -lt "$required" ]; then
        error_exit "Insufficient disk space. Available: ${available}MB, Required:  ${required}MB"
    fi

    log SUCCESS "Disk space check passed (${available}MB available)"

    # Check n8n container disk usage
    local n8n_usage=$(docker exec "$N8N_CONTAINER" df -h /home/node/. n8n | awk 'NR==2 {print $3, $4, $5}')
    log INFO "n8n container disk usage: ${n8n_usage}"
}

# Backup n8n workflows
backup_workflows() {
    log INFO "Starting workflows backup..."

    local backup_file="${BACKUP_DIR}/workflows_${TIMESTAMP}.json"
    local temp_file="${TEMP_DIR}/workflows. json"

    if [ "$TEST_MODE" = true ]; then
        log WARNING "TEST MODE:  Skipping actual backup"
        return 0
    fi

    # Export workflows
    log INFO "Exporting workflows from n8n..."
    if !  docker exec "$N8N_CONTAINER" n8n export: workflow --all --output=/tmp/workflows_export.json 2>&1 | tee -a "${LOG_FILE}"; then
        error_exit "Failed to export workflows"
    fi

    # Copy from container
    log INFO "Copying workflows from container..."
    if ! docker cp "${N8N_CONTAINER}:/tmp/workflows_export.json" "$temp_file"; then
        error_exit "Failed to copy workflows from container"
    fi

    # Validate JSON structure
    log INFO "Validating workflows JSON..."
    if ! python3 -c "import json; json.load(open('$temp_file'))" 2>&1 | tee -a "${LOG_FILE}"; then
        error_exit "Invalid JSON structure in workflows backup"
    fi

    # Count workflows
    local workflow_count=$(grep -o '"id": ' "$temp_file" | wc -l)
    log INFO "Workflows found: ${workflow_count}"

    if [ "$workflow_count" -eq 0 ]; then
        error_exit "No workflows found in backup"
    fi

    # Move to backup directory
    mv "$temp_file" "$backup_file"

    # Get file size
    local file_size=$(du -h "$backup_file" | cut -f1)
    log SUCCESS "Workflows backup completed:  $backup_file (${file_size}, ${workflow_count} workflows)"

    # Verify backup integrity
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        log SUCCESS "Workflows backup integrity verified"
    else
        error_exit "Workflows backup file is empty or missing"
    fi
}

# Backup PostgreSQL database
backup_database() {
    log INFO "Starting database backup..."

    local backup_file="${BACKUP_DIR}/database_${TIMESTAMP}.sql"
    local temp_file="${TEMP_DIR}/database.sql"

    if [ "$TEST_MODE" = true ]; then
        log WARNING "TEST MODE:  Skipping actual backup"
        return 0
    fi

    # Create pg_dump
    log INFO "Creating PostgreSQL dump..."
    if ! docker exec "$POSTGRES_CONTAINER" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$temp_file" 2>> "${LOG_FILE}"; then
        error_exit "Failed to create database dump"
    fi

    # Check if dump contains data
    local line_count=$(wc -l < "$temp_file")
    log INFO "Database dump lines: ${line_count}"

    if [ "$line_count" -lt 10 ]; then
        error_exit "Database dump appears to be empty or invalid"
    fi

    # Validate SQL syntax (basic check)
    if ! grep -q "PostgreSQL database dump" "$temp_file"; then
        error_exit "Database dump does not appear to be a valid PostgreSQL dump"
    fi

    # Move to backup directory
    mv "$temp_file" "$backup_file"

    # Compress backup
    log INFO "Compressing database backup..."
    gzip "$backup_file"
    backup_file="${backup_file}.gz"

    # Get file size
    local file_size=$(du -h "$backup_file" | cut -f1)
    log SUCCESS "Database backup completed:  $backup_file (${file_size})"

    # Verify backup integrity
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        log SUCCESS "Database backup integrity verified"
    else
        error_exit "Database backup file is empty or missing"
    fi
}

# Create backup manifest
create_manifest() {
    log INFO "Creating backup manifest..."

    local manifest_file="${BACKUP_DIR}/manifest_${TIMESTAMP}.txt"

    cat > "$manifest_file" <<EOF
================================================================================
n8n BACKUP MANIFEST
================================================================================
Timestamp: ${TIMESTAMP}
Date: $(date '+%Y-%m-%d %H:%M:%S %Z')
Hostname: $(hostname)
Script Version: 1.0

CONTAINER INFORMATION:
----------------------
n8n Container: ${N8N_CONTAINER}
PostgreSQL Container: ${POSTGRES_CONTAINER}

n8n Version: $(docker exec "$N8N_CONTAINER" n8n --version 2>/dev/null || echo "Unknown")
n8n Uptime: $(docker ps --filter "name=${N8N_CONTAINER}" --format '{{.Status}}')
PostgreSQL Version: $(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -c "SELECT version();" 2>/dev/null | head -3 | tail -1 || echo "Unknown")

BACKUP FILES:
-------------
Workflows:  workflows_${TIMESTAMP}.json
Database: database_${TIMESTAMP}.sql. gz

FILE SIZES:
-----------
$(ls -lh "${BACKUP_DIR}/workflows_${TIMESTAMP}.json" 2>/dev/null | awk '{print "Workflows:", $5}')
$(ls -lh "${BACKUP_DIR}/database_${TIMESTAMP}.sql.gz" 2>/dev/null | awk '{print "Database:", $5}')

CHECKSUMS (SHA256):
-------------------
$(sha256sum "${BACKUP_DIR}/workflows_${TIMESTAMP}.json" 2>/dev/null)
$(sha256sum "${BACKUP_DIR}/database_${TIMESTAMP}.sql.gz" 2>/dev/null)

DISK USAGE:
-----------
$(df -h "$BACKUP_DIR" | awk 'NR==2 {print "Backup partition:", $2, "total,", $3, "used,", $4, "available"}')
$(docker exec "$N8N_CONTAINER" df -h /home/node/.n8n | awk 'NR==2 {print "n8n container:", $2, "total,", $3, "used,", $4, "available"}')

WORKFLOW COUNT:
---------------
Total workflows: $(grep -o '"id":' "${BACKUP_DIR}/workflows_${TIMESTAMP}.json" | wc -l)

DATABASE STATISTICS:
--------------------
$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" "$POSTGRES_DB" -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;" 2>/dev/null || echo "Unable to retrieve statistics")

================================================================================
EOF

    log SUCCESS "Manifest created:  $manifest_file"
}

# Rotate old backups
rotate_backups() {
    log INFO "Rotating old backups (keeping last ${KEEP_BACKUPS})..."

    local workflow_files=$(ls -t "${BACKUP_DIR}"/workflows_*. json 2>/dev/null || true)
    local db_files=$(ls -t "${BACKUP_DIR}"/database_*.sql.gz 2>/dev/null || true)
    local manifest_files=$(ls -t "${BACKUP_DIR}"/manifest_*.txt 2>/dev/null || true)

    # Count current backups
    local workflow_count=$(echo "$workflow_files" | grep -c .  || echo 0)
    local db_count=$(echo "$db_files" | grep -c . || echo 0)

    log INFO "Current backup count: ${workflow_count} workflows, ${db_count} databases"

    # Remove old workflow backups
    if [ "$workflow_count" -gt "$KEEP_BACKUPS" ]; then
        echo "$workflow_files" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
            log INFO "Removing old workflow backup:  $(basename "$file")"
            rm -f "$file"
        done
    fi

    # Remove old database backups
    if [ "$db_count" -gt "$KEEP_BACKUPS" ]; then
        echo "$db_files" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
            log INFO "Removing old database backup: $(basename "$file")"
            rm -f "$file"
        done
    fi

    # Remove old manifests
    echo "$manifest_files" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r file; do
        [ -f "$file" ] && rm -f "$file"
    done

    log SUCCESS "Backup rotation completed"
}

# Print summary
print_summary() {
    log INFO "Generating backup summary..."

    echo ""
    echo "================================================================================"
    echo "                          BACKUP SUMMARY"
    echo "================================================================================"
    echo ""
    echo "Timestamp:           ${TIMESTAMP}"
    echo "Backup Directory:   ${BACKUP_DIR}"
    echo "Log File:           ${LOG_FILE}"
    echo ""
    echo "Files Created:"
    echo "  - workflows_${TIMESTAMP}.json"
    echo "  - database_${TIMESTAMP}.sql.gz"
    echo "  - manifest_${TIMESTAMP}. txt"
    echo ""
    echo "Backup Sizes:"
    ls -lh "${BACKUP_DIR}/workflows_${TIMESTAMP}.json" "${BACKUP_DIR}/database_${TIMESTAMP}.sql.gz" 2>/dev/null | \
        awk '{printf "  - %-40s %s\n", $9, $5}'
    echo ""
    echo "Total Backup Size:"
    du -sh "$BACKUP_DIR" | awk '{print "  ", $1}'
    echo ""
    echo "Backup Retention:    Last ${KEEP_BACKUPS} backups"
    echo "Current Backups:    $(ls "${BACKUP_DIR}"/workflows_*.json 2>/dev/null | wc -l) workflow sets"
    echo ""
    echo "================================================================================"
    echo ""
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -t|--test)
                TEST_MODE=true
                shift
                ;;
            -k|--keep)
                KEEP_BACKUPS="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  -v, --verbose    Enable verbose output"
                echo "  -t, --test       Test mode (no actual backup)"
                echo "  -k, --keep N     Keep last N backups (default: 7)"
                echo "  -h, --help       Show this help message"
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo ""
    echo "================================================================================"
    echo "                    n8n BACKUP SCRIPT WITH DIAGNOSTICS"
    echo "================================================================================"
    echo ""

    # Parse arguments
    parse_arguments "$@"

    # Setup
    setup_directories

    # Pre-flight checks
    log INFO "Starting pre-flight checks..."
    check_docker
    check_containers
    check_disk_space

    # Perform backups
    if [ "$TEST_MODE" = false ]; then
        log INFO "Starting backup process..."
        backup_workflows
        backup_database
        create_manifest
        rotate_backups
    else
        log WARNING "Running in TEST MODE - no backups will be created"
    fi

    # Summary
    print_summary

    log SUCCESS "Backup completed successfully!"

    return 0
}

# Run main function
main "$@"
