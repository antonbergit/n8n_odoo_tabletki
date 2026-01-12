#!/bin/bash

cd /opt/n8n

echo "============================================================================"
echo "                    BACKUP/RESTORE CYCLE TEST"
echo "============================================================================"
echo ""

# ============================================================================
# ТЕСТ 1: Створити backup
# ============================================================================
echo "1. Creating backup..."
./backup_n8n.sh --verbose

# Зберегти timestamp
BACKUP_TS=$(ls -t backups/workflows_*.json 2>/dev/null | head -1 | sed 's/.*workflows_\(.*\)\.json/\1/')
echo "Backup timestamp:  $BACKUP_TS"

if [ -z "$BACKUP_TS" ]; then
    echo "❌ FAILED:  No backup created"
    exit 1
fi

# ============================================================================
# ТЕСТ 2: Перевірити backup
# ============================================================================
echo ""
echo "2. Verifying backup..."
./verify_backups.sh

# ============================================================================
# ТЕСТ 3: Зробити тестову зміну
# ============================================================================
echo ""
echo "3. Making test change..."

# Запам'ятай скільки workflows зараз
BEFORE=$(docker exec n8n-n8n-1 n8n list:workflow 2>/dev/null | wc -l)
echo "Workflows before: $BEFORE"

# Створити тестовий JSON локально
cat > /tmp/host_test_workflow.json << 'EOFWORKFLOW'
{
  "name": "DELETE_ME_TEST",
  "nodes": [
    {
      "parameters": {},
      "name": "Start",
      "type": "n8n-nodes-base.start",
      "typeVersion": 1,
      "position": [250, 300]
    }
  ],
  "connections":  {},
  "active": false,
  "settings": {},
  "tags": []
}
EOFWORKFLOW

# Копіювати в контейнер
docker cp /tmp/host_test_workflow.json n8n-n8n-1:/tmp/test.json

# Перевірити що файл створився
if docker exec n8n-n8n-1 test -f /tmp/test.json; then
    echo "✓ Test workflow file created"
    
    # Імпортувати workflow
    echo "Importing test workflow..."
    docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/test.json
    
    AFTER=$(docker exec n8n-n8n-1 n8n list:workflow 2>/dev/null | wc -l)
    echo "Workflows after: $AFTER"
    
    if [ "$AFTER" -gt "$BEFORE" ]; then
        echo "✓ Test workflow added successfully"
    else
        echo "⚠️ WARNING:  Workflow count didn't increase"
    fi
else
    echo "❌ Failed to create test workflow file"
    exit 1
fi

# ============================================================================
# ТЕСТ 4: Restore
# ============================================================================
echo ""
echo "4. Restoring from backup $BACKUP_TS..."

# Restore (автоматичний yes)
echo "yes" | ./restore_n8n. sh "$BACKUP_TS"

echo "Restarting n8n..."
docker restart n8n-n8n-1 > /dev/null 2>&1
echo "Waiting for n8n to start (15 seconds)..."
sleep 15

# ============================================================================
# ТЕСТ 5: Перевірити результат
# ============================================================================
echo ""
echo "5. Verifying restore..."
FINAL=$(docker exec n8n-n8n-1 n8n list:workflow 2>/dev/null | wc -l)
echo "Workflows after restore:  $FINAL"

echo ""
echo "============================================================================"
echo "                    RESULTS"
echo "============================================================================"
echo "Before backup:    $BEFORE workflows"
echo "After test add:   $AFTER workflows"
echo "After restore:     $FINAL workflows"
echo ""

if [ "$FINAL" -eq "$BEFORE" ]; then
    echo "��� SUCCESS: Restored to original state!"
    echo "✅ Test workflow was removed as expected"
    echo ""
    echo "BACKUP/RESTORE SYSTEM IS FULLY OPERATIONAL!  🎉"
else
    echo "❌ FAIL: Expected $BEFORE workflows, got $FINAL"
fi

echo "============================================================================"
echo ""
