cat > /opt/n8n/diagnose_backup.sh << 'EOFDIAG'
#!/bin/bash

echo "================================================================================"
echo "                    BACKUP SYSTEM DIAGNOSTICS"
echo "================================================================================"
echo ""

cd /opt/n8n

# ============================================================================
# TEST 1: Перевірка export команди
# ============================================================================
echo "TEST 1: n8n export command"
echo "-------------------------------------------"

if docker exec n8n-n8n-1 n8n export: workflow --all --output=/tmp/diag_test.json 2>&1 | grep -q "Successfully exported"; then
    echo "✅ Export command works"
    EXPORT_COUNT=$(docker exec n8n-n8n-1 n8n export: workflow --all --output=/tmp/diag_test.json 2>&1 | grep -oP '\d+(? = workflows)')
    echo "   Exported:  $EXPORT_COUNT workflows"
else
    echo "❌ Export command failed"
    exit 1
fi

# ============================================================================
# TEST 2: Перевірка JSON структури
# ============================================================================
echo ""
echo "TEST 2: JSON structure"
echo "-------------------------------------------"

docker cp n8n-n8n-1:/tmp/diag_test.json /tmp/diag_local.json

# Показати перші 200 символів
echo "First 200 chars of JSON:"
head -c 200 /tmp/diag_local.json
echo ""
echo ""

# Перевірити чи це масив
if python3 -c "import json; data=json.load(open('/tmp/diag_local.json')); exit(0 if isinstance(data, list) else 1)" 2>/dev/null; then
    echo "✅ JSON is an array"
else
    echo "❌ JSON is not an array"
fi

# Підрахувати workflows
WF_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/diag_local. json'))))" 2>/dev/null)
echo "✅ Python count: $WF_COUNT workflows"

# ============================================================================
# TEST 3: Grep patterns
# ============================================================================
echo ""
echo "TEST 3: Different grep patterns"
echo "-------------------------------------------"

echo "Pattern 1 (with space): '\"id\": '"
GREP1=$(grep -o '"id": ' /tmp/diag_local.json | wc -l)
echo "  Result: $GREP1 matches"

echo "Pattern 2 (without space): '\"id\":'"
GREP2=$(grep -o '"id":' /tmp/diag_local.json | wc -l)
echo "  Result: $GREP2 matches"

echo "Pattern 3 (with regex): '\"id\"\\s*: '"
GREP3=$(grep -oE '"id"\s*: ' /tmp/diag_local.json | wc -l)
echo "  Result: $GREP3 matches"

# ============================================================================
# TEST 4: Перевірка backup_n8n.sh
# ============================================================================
echo ""
echo "TEST 4: Current backup script"
echo "-------------------------------------------"

if grep -q 'python3 -c "import json' backup_n8n.sh; then
    echo "✅ Script uses Python for counting"
else
    echo "❌ Script still uses grep for counting"
    echo "   Current line:"
    grep "workflow_count=" backup_n8n.sh | head -1
fi

# ============================================================================
# TEST 5: Spaces in commands
# ============================================================================
echo ""
echo "TEST 5: Command formatting"
echo "-------------------------------------------"

if grep -q 'export:  workflow' backup_n8n. sh; then
    echo "❌ Script has extra space in 'export:  workflow'"
else
    echo "✅ No extra spaces in export command"
fi

if grep -q 'import:  workflow' restore_n8n.sh; then
    echo "❌ restore_n8n.sh has extra space in 'import:  workflow'"
else
    echo "✅ No extra spaces in import command"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "================================================================================"
echo "                    SUMMARY"
echo "================================================================================"
echo ""
echo "Expected workflow count: $EXPORT_COUNT"
echo "Python JSON count:        $WF_COUNT"
echo "Grep pattern 1:          $GREP1"
echo "Grep pattern 2:          $GREP2"
echo "Grep pattern 3:          $GREP3"
echo ""

if [ "$WF_COUNT" -eq "$EXPORT_COUNT" ]; then
    echo "✅ Python counting works correctly!"
else
    echo "❌ Counting mismatch"
fi

echo ""
echo "================================================================================"

# Cleanup
rm -f /tmp/diag_local.json
docker exec n8n-n8n-1 rm -f /tmp/diag_test. json

EOFDIAG

chmod +x /opt/n8n/diagnose_backup.sh
